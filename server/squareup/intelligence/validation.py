"""Deterministic checks on a provider proposal (milestone 5 §5.3, §6).

Turns a :class:`RawProposal` into the app-facing proposal: money as integer minor units, region
aliases mapped back to the client's identifiers, and an attention state per value. It never changes
a value to make the receipt balance. Disagreements become attention and issues with exact
differences; only output that can't be represented safely raises :class:`InvalidOutput`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from ..domain.money import MAX_ABS_MINOR_UNITS, minor_unit_digits
from .prompt import RegionAliases
from .schema import InvalidOutput, RawField, RawProposal

#: Currencies the receipt pipeline accepts (ISO 4217). Anything else is ``unsupported_currency``.
SUPPORTED_CURRENCIES = frozenset(
    {
        "USD", "CAD", "MXN", "EUR", "GBP", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "ISK",
        "AUD", "NZD", "JPY", "KRW", "CNY", "HKD", "TWD", "SGD", "INR", "THB", "MYR", "PHP", "IDR",
        "VND", "AED", "SAR", "ILS", "TRY", "ZAR", "BRL", "ARS", "CLP", "COP", "PEN", "KWD", "BHD",
        "OMR", "JOD",
    }
)  # fmt: skip

LOOKS_GOOD, CHECK, NEEDS_RESOLUTION = "looksGood", "check", "needsResolution"
_RANK = {LOOKS_GOOD: 0, CHECK: 1, NEEDS_RESOLUTION: 2}
_UNCERTAINTY_REASON = {
    "multipleCandidates": "multipleCandidates",
    "ambiguousCharacters": "ambiguousFormat",
    "notPrinted": "notFound",
    "arithmeticMismatch": "mathConflict",
}
_PLAIN = re.compile(r"^(-?)(\d{1,15})(?:\.(\d+))?$")
_GROUPED = re.compile(r"^(-?)(\d{1,3}(?:,\d{3})+)(?:\.(\d+))?$")
_QUANTITY = re.compile(r"^\d{1,4}$")


def parse_money(text: str, digits: int) -> int:
    """Exact decimal string → signed minor units. Raises ``InvalidOutput('malformed_money')``.

    Accepts "12.50", "-3.00", "1,234.56", and whole numbers ("12" → 12.00). Rejects a partial
    fraction ("12.5"), extra digits ("12.505"), symbols, exponents, and anything over the API bound.
    """
    candidate = text.strip()
    match = _PLAIN.match(candidate) or _GROUPED.match(candidate)
    if match is None:
        raise InvalidOutput("malformed_money")
    sign, whole, fraction = match.group(1), match.group(2).replace(",", ""), match.group(3)
    if fraction is not None and len(fraction) != digits:
        raise InvalidOutput("malformed_money")
    units: int = int(whole) * pow(10, digits) + (int(fraction) if fraction else 0)
    if units > MAX_ABS_MINOR_UNITS:
        raise InvalidOutput("malformed_money")
    return -units if sign else units


def _money_text(units: int, digits: int) -> str:
    magnitude = abs(units)
    if digits == 0:
        return str(magnitude)
    return f"{magnitude // 10**digits}.{magnitude % 10**digits:0{digits}d}"


def _compact(text: str) -> str:
    return "".join(ch for ch in text if ch.isdigit() or ch in ".,").replace(",", ".")


@dataclass
class Validated:
    proposal: dict[str, Any]
    issues: list[dict[str, Any]]
    unknown_region_refs: int
    evidence_mismatches: int
    reconciled: bool


@dataclass
class _Context:
    aliases: RegionAliases
    digits: int
    unknown: int = 0
    evidence_mismatches: int = 0
    issues: list[dict[str, Any]] = field(default_factory=list)


def _initial(raw: RawField) -> tuple[str, str]:
    if raw.value is None:
        return CHECK, "notFound"
    if raw.confidence == "high" and raw.uncertainty == "none":
        return LOOKS_GOOD, "strongEvidence"
    return CHECK, _UNCERTAINTY_REASON.get(raw.uncertainty, "lowConfidence")


def _raise(field_out: dict[str, Any], attention: str, reason: str) -> None:
    if _RANK[attention] > _RANK[field_out["attention"]]:
        field_out["attention"], field_out["reason"] = attention, reason


def _field(ctx: _Context, raw: RawField, value: Any) -> dict[str, Any]:
    region_ids, unknown = ctx.aliases.resolve(raw.region_ids)
    ctx.unknown += unknown
    attention, reason = _initial(raw)
    out = {"value": value, "attention": attention, "reason": reason, "basis": raw.basis, "regionIds": region_ids}
    if value is not None and raw.basis == "visible" and not region_ids:
        _raise(out, CHECK, "noEvidence")
    return out


def _money_field(ctx: _Context, raw: RawField, *, total: bool = False) -> dict[str, Any]:
    units = None if raw.value is None else parse_money(raw.value, ctx.digits)
    out = _field(ctx, raw, units)
    if units is None:
        return out
    if raw.basis in ("layout", "arithmetic"):
        _raise(out, NEEDS_RESOLUTION if total else CHECK, "derived")
    elif out["regionIds"]:
        # Cross-check the reading against Vision's top reading: Claude may legitimately correct an
        # OCR misread (even choosing one of Vision's lower-ranked alternatives), but the person should
        # then look at it rather than trust either reading silently.
        printed = _money_text(units, ctx.digits)
        cited = ctx.aliases.regions(raw.region_ids)
        if not any(printed in _compact(region.text) for region in cited):
            ctx.evidence_mismatches += 1
            _raise(out, CHECK, "evidenceMismatch")
    return out


def _issue(ctx: _Context, code: str, **details: Any) -> None:
    ctx.issues.append({"code": code, **details})


def validate(raw: RawProposal, aliases: RegionAliases, *, likely_currency: str | None) -> Validated:
    """Deterministic validation; raises :class:`InvalidOutput` only for unusable output."""
    # Currency first: it decides how every amount is read.
    currency = (raw.currency.value or "").strip().upper()
    currency_defaulted = False
    if not currency and likely_currency in SUPPORTED_CURRENCIES:
        currency, currency_defaulted = likely_currency or "", True
    if currency not in SUPPORTED_CURRENCIES:
        raise InvalidOutput("unsupported_currency")
    ctx = _Context(aliases, minor_unit_digits(currency))

    currency_field = _field(ctx, raw.currency, currency)
    if currency_defaulted:
        currency_field.update(attention=CHECK, reason="defaultValue", basis="absent")

    merchant_text = (raw.merchant.value or "").strip()
    merchant = _field(ctx, raw.merchant, merchant_text)
    if not merchant_text:
        merchant.update(attention=NEEDS_RESOLUTION, reason="notFound")

    parsed_date = None
    if raw.date.value is not None:
        try:
            parsed = date.fromisoformat(raw.date.value.strip())
        except ValueError as error:
            raise InvalidOutput("malformed_date") from error
        if not 1990 <= parsed.year <= 2100:
            raise InvalidOutput("malformed_date")
        parsed_date = parsed.isoformat()
    date_field = _field(ctx, raw.date, parsed_date)

    items: list[dict[str, Any]] = []
    for index, raw_item in enumerate(raw.items):
        name_text = (raw_item.name.value or "").strip()
        name = _field(ctx, raw_item.name, name_text)
        if not name_text:
            name.update(attention=CHECK, reason="notFound")
        line = _money_field(ctx, raw_item.line_total)
        if line["value"] is None:
            # Never invent an amount: zero, flagged, so the receipt can't reconcile silently.
            line.update(value=0, attention=NEEDS_RESOLUTION, reason="notFound")
            _issue(ctx, "itemAmountMissing", item=index)
        unit_price = None if raw_item.unit_price.value is None else parse_money(raw_item.unit_price.value, ctx.digits)
        quantity_text = (raw_item.quantity.value or "").strip()
        quantity = int(quantity_text) if _QUANTITY.match(quantity_text) and int(quantity_text) > 0 else None
        if quantity_text and quantity is None:
            _raise(line, CHECK, "quantityMismatch")
            _issue(ctx, "quantityUnreadable", item=index)
        if quantity is not None and unit_price is not None and quantity * unit_price != line["value"]:
            _raise(line, CHECK, "quantityMismatch")
            _issue(ctx, "quantityTimesPriceMismatch", item=index, difference=line["value"] - quantity * unit_price)
        if line["value"] < 0 and not raw_item.is_refund:
            _raise(line, NEEDS_RESOLUTION, "invalidValue")
            _issue(ctx, "negativeItemNotRefund", item=index)
        if raw_item.is_refund and line["value"] > 0:
            _raise(line, NEEDS_RESOLUTION, "invalidValue")
            _issue(ctx, "refundNotNegative", item=index)
        items.append({"name": name, "quantity": quantity, "unitPrice": unit_price, "lineTotal": line, "isRefund": raw_item.is_refund})

    # Adjacent lines with the same name and amount: flagged, never removed.
    for index in range(1, len(items)):
        previous, current = items[index - 1], items[index]
        same_name = previous["name"]["value"].lower() == current["name"]["value"].lower() and current["name"]["value"]
        if same_name and previous["lineTotal"]["value"] == current["lineTotal"]["value"]:
            _raise(current["lineTotal"], CHECK, "possibleDuplicate")
            _issue(ctx, "possibleDuplicate", item=index)

    charges: list[dict[str, Any]] = []
    notes: list[dict[str, Any]] = []
    for raw_charge in raw.charges:
        amount = _money_field(ctx, raw_charge.amount)
        value = amount["value"]
        if value is None:
            amount.update(value=0, attention=NEEDS_RESOLUTION, reason="notFound")
            _issue(ctx, "chargeAmountMissing", charge=len(charges))
        elif value == 0:
            # A blank or zero line (e.g. an empty tip line) is a note, as in the on-device parser.
            notes.append({"kind": "blankCharge", "chargeKind": raw_charge.kind})
            continue
        elif raw_charge.kind == "discount" and value > 0:
            amount["value"] = -value  # discounts are stored negative (same convention on device)
        elif raw_charge.kind in ("tax", "tip", "serviceCharge", "fee") and value < 0:
            _raise(amount, NEEDS_RESOLUTION, "invalidValue")
            _issue(ctx, "chargeSignInvalid", charge=len(charges))
        label = raw_charge.label.strip()
        if raw_charge.kind == "adjustment" and not label:
            _raise(amount, NEEDS_RESOLUTION, "invalidValue")
        charges.append({"kind": raw_charge.kind, "label": label, "amount": amount})

    subtotal = _money_field(ctx, raw.subtotal)
    total = _money_field(ctx, raw.total, total=True)
    if total["value"] is None:
        total.update(attention=NEEDS_RESOLUTION, reason="notFound")
    if not items and total["value"] is None:
        raise InvalidOutput("nothing_extracted")

    items_sum = sum(item["lineTotal"]["value"] for item in items)
    charges_sum = sum(charge["amount"]["value"] for charge in charges)
    if subtotal["value"] is not None and subtotal["value"] != items_sum:
        _raise(subtotal, CHECK, "mathConflict")
        _issue(ctx, "subtotalMismatch", difference=subtotal["value"] - items_sum)
    reconciled = False
    if total["value"] is not None:
        if total["value"] <= 0:
            _raise(total, NEEDS_RESOLUTION, "invalidValue")
            _issue(ctx, "totalNotPositive")
        difference = total["value"] - (items_sum + charges_sum)
        reconciled = difference == 0
        if not reconciled:
            _raise(total, CHECK, "mathConflict")
            _issue(ctx, "totalMismatch", difference=difference)
    if ctx.unknown:
        _issue(ctx, "unknownRegionReferences", count=ctx.unknown)

    warnings = []
    for code, refs in raw.warnings:
        region_ids, unknown = aliases.resolve(refs)
        ctx.unknown += unknown
        warnings.append({"code": code, "regionIds": region_ids})
    proposal = {
        "merchant": merchant,
        "date": date_field,
        "currency": currency_field,
        "items": items,
        "charges": charges,
        "subtotal": subtotal,
        "total": total,
        "notes": notes,
        "warnings": warnings,
        "overallConfidence": raw.overall_confidence,
    }
    return Validated(proposal, ctx.issues, ctx.unknown, ctx.evidence_mismatches, reconciled)
