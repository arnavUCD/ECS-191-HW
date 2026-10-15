"""Versioned request and response contracts (milestone 5 §4–§5).

Two directions, both strict:

- :func:`parse_request` validates what the app sends (types, sizes, counts, ranges) and refuses
  anything else with ``invalid_payload`` before an image is decoded or a provider is called.
- :func:`parse_provider_output` checks the provider's JSON against :data:`PROVIDER_OUTPUT_SCHEMA`
  by hand: required keys, no extra keys, enumerations, list and string bounds. Structured outputs
  already constrain the model, but nothing the provider returns is trusted until this passes.
"""

from __future__ import annotations

import base64
import binascii
import json
import math
from dataclasses import dataclass
from typing import Any

from ..domain.errors import DomainError

SCHEMA_VERSION = 1
CONSENT_VERSION = 1

QUALITY_WARNINGS = ("blurry", "tooDark", "overexposed", "lowContrast", "edgesMissing", "lowResolution")
CONFIDENCE = ("high", "medium", "low")
BASIS = ("visible", "layout", "arithmetic", "absent")
UNCERTAINTY = (
    "none",
    "blurry",
    "cropped",
    "ambiguousCharacters",
    "handwritten",
    "abbreviation",
    "multipleCandidates",
    "notPrinted",
    "arithmeticMismatch",
    "other",
)
CHARGE_KINDS = ("tax", "tip", "serviceCharge", "fee", "discount", "adjustment")
WARNING_CODES = (
    "instructionTextIgnored",
    "cardDetailsIgnored",
    "partialReceipt",
    "multipleReceipts",
    "handwritten",
    "lowImageQuality",
    "notAReceipt",
    "taxIncluded",
    "blankCharge",
    "other",
)

MAX_REGION_TEXT = 300
MAX_ALTERNATIVES = 2
MAX_ITEMS = 400
MAX_CHARGES = 60
MAX_WARNINGS = 40
MAX_REGION_REFS = 40
MAX_OUTPUT_CHARS = 200_000
MAX_STRING = {"merchant": 200, "name": 300, "label": 120, "value": 64}


class InvalidOutput(Exception):
    """The provider's response can't be used. ``reason`` is a stable, content-free code."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


# MARK: - Request


@dataclass(frozen=True)
class PageInput:
    index: int
    image: bytes
    warnings: tuple[str, ...]


@dataclass(frozen=True)
class RegionInput:
    client_id: str
    page: int
    order: int
    text: str
    confidence: float
    box: tuple[float, float, float, float]
    alternatives: tuple[str, ...]


@dataclass(frozen=True)
class ParseRequest:
    pages: list[PageInput]
    regions: list[RegionInput]
    locale: str | None
    likely_currency: str | None
    consent_mode: str
    consent_version: int


def _fail(message: str = "That receipt request isn't valid") -> DomainError:
    return DomainError("invalid_payload", message)


def _number(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
        raise _fail()
    return float(value)


def _text(value: object, limit: int) -> str:
    if not isinstance(value, str) or len(value) > limit:
        raise _fail()
    return value


def parse_request(body: object, *, max_pages: int, max_regions: int, max_image_bytes: int) -> ParseRequest:
    """Validate the app's request. Raises ``invalid_payload`` / ``payload_too_large``."""
    if not isinstance(body, dict):
        raise _fail("Expected a JSON object")
    if body.get("schemaVersion") != SCHEMA_VERSION:
        raise _fail("Unsupported schema version")
    consent = body.get("consent")
    if not isinstance(consent, dict):
        raise DomainError("ai_consent_required", "AI processing needs your permission first")
    mode, version = consent.get("mode"), consent.get("version")
    if mode != "automatic" or version != CONSENT_VERSION:
        raise DomainError("ai_consent_required", "AI processing needs your permission first")

    raw_pages = body.get("pages")
    if not isinstance(raw_pages, list) or not raw_pages:
        raise _fail("A receipt needs at least one page")
    if len(raw_pages) > max_pages:
        raise DomainError("payload_too_large", "That receipt has too many pages")
    pages: list[PageInput] = []
    for expected_index, page in enumerate(raw_pages):
        if not isinstance(page, dict) or page.get("index") != expected_index:
            raise _fail()
        encoded = page.get("image")
        if not isinstance(encoded, str) or not encoded:
            raise _fail()
        if len(encoded) > (max_image_bytes * 4) // 3 + 8:
            raise DomainError("payload_too_large", "That image is too large")
        try:
            image = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            raise _fail() from error
        if len(image) > max_image_bytes:
            raise DomainError("payload_too_large", "That image is too large")
        warnings = page.get("warnings", [])
        if not isinstance(warnings, list) or any(w not in QUALITY_WARNINGS for w in warnings) or len(warnings) > len(QUALITY_WARNINGS):
            raise _fail()
        pages.append(PageInput(expected_index, image, tuple(warnings)))

    raw_regions = body.get("regions", [])
    if not isinstance(raw_regions, list):
        raise _fail()
    if len(raw_regions) > max_regions:
        raise DomainError("payload_too_large", "That receipt has too much text")
    regions: list[RegionInput] = []
    seen: set[str] = set()
    for region in raw_regions:
        if not isinstance(region, dict):
            raise _fail()
        client_id = _text(region.get("id"), 64)
        if not client_id or client_id in seen:
            raise _fail()
        seen.add(client_id)
        page_index, order = region.get("page"), region.get("order")
        if not isinstance(page_index, int) or isinstance(page_index, bool) or not 0 <= page_index < len(pages):
            raise _fail()
        if not isinstance(order, int) or isinstance(order, bool) or not 0 <= order <= 100_000:
            raise _fail()
        confidence = _number(region.get("confidence"))
        box = region.get("box")
        if not isinstance(box, list) or len(box) != 4:
            raise _fail()
        x, y, w, h = (_number(v) for v in box)
        if not (0 <= confidence <= 1 and -0.01 <= x <= 1.01 and -0.01 <= y <= 1.01 and 0 <= w <= 1.01 and 0 <= h <= 1.01):
            raise _fail()
        alternatives = region.get("alternatives", [])
        if not isinstance(alternatives, list) or len(alternatives) > MAX_ALTERNATIVES:
            raise _fail()
        regions.append(
            RegionInput(
                client_id=client_id,
                page=page_index,
                order=order,
                text=_text(region.get("text"), MAX_REGION_TEXT),
                confidence=confidence,
                box=(x, y, w, h),
                alternatives=tuple(_text(a, MAX_REGION_TEXT) for a in alternatives),
            )
        )

    locale = body.get("locale")
    if locale is not None and (
        not isinstance(locale, str) or not 2 <= len(locale) <= 35 or not locale.replace("_", "-").replace("-", "").isalnum()
    ):
        raise _fail()
    currency = body.get("likelyCurrency")
    if currency is not None and (not isinstance(currency, str) or len(currency) != 3 or not currency.isalpha() or not currency.isascii()):
        raise _fail()
    return ParseRequest(
        pages=pages,
        regions=sorted(regions, key=lambda r: (r.page, r.order)),
        locale=locale,
        likely_currency=currency.upper() if isinstance(currency, str) else None,
        consent_mode=mode,
        consent_version=version,
    )


# MARK: - Provider output


def _field_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "value": {"anyOf": [{"type": "string"}, {"type": "null"}]},
            "confidence": {"type": "string", "enum": list(CONFIDENCE)},
            "basis": {"type": "string", "enum": list(BASIS)},
            "regionIds": {"type": "array", "items": {"type": "string"}},
            "uncertainty": {"type": "string", "enum": list(UNCERTAINTY)},
        },
        "required": ["value", "confidence", "basis", "regionIds", "uncertainty"],
        "additionalProperties": False,
    }


#: Strict JSON Schema sent with ``output_config.format``. Only features structured outputs support
#: (no numeric or string-length constraints); bounds are enforced in :func:`parse_provider_output`.
PROVIDER_OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "$defs": {"field": _field_schema()},
    "properties": {
        "merchant": {"$ref": "#/$defs/field"},
        "date": {"$ref": "#/$defs/field"},
        "currency": {"$ref": "#/$defs/field"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"$ref": "#/$defs/field"},
                    "quantity": {"$ref": "#/$defs/field"},
                    "unitPrice": {"$ref": "#/$defs/field"},
                    "lineTotal": {"$ref": "#/$defs/field"},
                    "isRefund": {"type": "boolean"},
                },
                "required": ["name", "quantity", "unitPrice", "lineTotal", "isRefund"],
                "additionalProperties": False,
            },
        },
        "charges": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "enum": list(CHARGE_KINDS)},
                    "label": {"type": "string"},
                    "amount": {"$ref": "#/$defs/field"},
                },
                "required": ["kind", "label", "amount"],
                "additionalProperties": False,
            },
        },
        "subtotal": {"$ref": "#/$defs/field"},
        "total": {"$ref": "#/$defs/field"},
        "warnings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "code": {"type": "string", "enum": list(WARNING_CODES)},
                    "regionIds": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["code", "regionIds"],
                "additionalProperties": False,
            },
        },
        "overallConfidence": {"type": "string", "enum": list(CONFIDENCE)},
    },
    "required": ["merchant", "date", "currency", "items", "charges", "subtotal", "total", "warnings", "overallConfidence"],
    "additionalProperties": False,
}


@dataclass(frozen=True)
class RawField:
    value: str | None
    confidence: str
    basis: str
    region_ids: tuple[str, ...]
    uncertainty: str


@dataclass(frozen=True)
class RawItem:
    name: RawField
    quantity: RawField
    unit_price: RawField
    line_total: RawField
    is_refund: bool


@dataclass(frozen=True)
class RawCharge:
    kind: str
    label: str
    amount: RawField


@dataclass(frozen=True)
class RawProposal:
    merchant: RawField
    date: RawField
    currency: RawField
    items: list[RawItem]
    charges: list[RawCharge]
    subtotal: RawField
    total: RawField
    warnings: list[tuple[str, tuple[str, ...]]]
    overall_confidence: str


def _object(value: object, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise InvalidOutput("schema_mismatch")
    return value


def _enum(value: object, allowed: tuple[str, ...]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise InvalidOutput("schema_mismatch")
    return value


def _refs(value: object) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > MAX_REGION_REFS or not all(isinstance(r, str) and len(r) <= 16 for r in value):
        raise InvalidOutput("schema_mismatch")
    return tuple(value)


def _field(value: object, limit: int) -> RawField:
    data = _object(value, {"value", "confidence", "basis", "regionIds", "uncertainty"})
    raw = data["value"]
    if raw is not None and (not isinstance(raw, str) or len(raw) > limit):
        raise InvalidOutput("schema_mismatch")
    return RawField(
        value=raw,
        confidence=_enum(data["confidence"], CONFIDENCE),
        basis=_enum(data["basis"], BASIS),
        region_ids=_refs(data["regionIds"]),
        uncertainty=_enum(data["uncertainty"], UNCERTAINTY),
    )


def parse_provider_output(text: str) -> RawProposal:
    """Strictly decode the provider's JSON. Raises :class:`InvalidOutput` on any deviation."""
    if len(text) > MAX_OUTPUT_CHARS:
        raise InvalidOutput("output_too_large")
    try:
        decoded = json.loads(text)
    except (json.JSONDecodeError, RecursionError) as error:
        raise InvalidOutput("not_json") from error
    top = _object(decoded, set(PROVIDER_OUTPUT_SCHEMA["required"]))
    money = MAX_STRING["value"]
    raw_items = top["items"]
    raw_charges = top["charges"]
    raw_warnings = top["warnings"]
    if not isinstance(raw_items, list) or len(raw_items) > MAX_ITEMS:
        raise InvalidOutput("schema_mismatch")
    if not isinstance(raw_charges, list) or len(raw_charges) > MAX_CHARGES:
        raise InvalidOutput("schema_mismatch")
    if not isinstance(raw_warnings, list) or len(raw_warnings) > MAX_WARNINGS:
        raise InvalidOutput("schema_mismatch")
    items = []
    for raw in raw_items:
        item = _object(raw, {"name", "quantity", "unitPrice", "lineTotal", "isRefund"})
        if not isinstance(item["isRefund"], bool):
            raise InvalidOutput("schema_mismatch")
        items.append(
            RawItem(
                name=_field(item["name"], MAX_STRING["name"]),
                quantity=_field(item["quantity"], money),
                unit_price=_field(item["unitPrice"], money),
                line_total=_field(item["lineTotal"], money),
                is_refund=item["isRefund"],
            )
        )
    charges = []
    for raw in raw_charges:
        charge = _object(raw, {"kind", "label", "amount"})
        label = charge["label"]
        if not isinstance(label, str) or len(label) > MAX_STRING["label"]:
            raise InvalidOutput("schema_mismatch")
        charges.append(RawCharge(_enum(charge["kind"], CHARGE_KINDS), label, _field(charge["amount"], money)))
    warnings = []
    for raw in raw_warnings:
        warning = _object(raw, {"code", "regionIds"})
        warnings.append((_enum(warning["code"], WARNING_CODES), _refs(warning["regionIds"])))
    return RawProposal(
        merchant=_field(top["merchant"], MAX_STRING["merchant"]),
        date=_field(top["date"], money),
        currency=_field(top["currency"], money),
        items=items,
        charges=charges,
        subtotal=_field(top["subtotal"], money),
        total=_field(top["total"], money),
        warnings=warnings,
        overall_confidence=_enum(top["overallConfidence"], CONFIDENCE),
    )
