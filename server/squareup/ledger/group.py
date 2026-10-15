"""The shared-group aggregate: how one group is stored, parsed from input, and shown to a member.

A group is one stored document (``SharedGroup``) holding its header, member seats, current expense
revisions, payment attempts, confirmed settlements, adopted receipt rooms, and the most recent
events. Keeping the money records together means every command validates and commits against one
consistent ledger in one transaction. Immutable expense revisions and the full event history are
also written as separate append-only records.

Seats (``members``):

- ``active``: bound to exactly one account (``uid``) and able to act.
- ``pending``: a named person from a published local group (or added by the owner) who hasn't
  accepted their seat invitation. They can appear in expenses; they can't act, receive payment
  confirmations, or see anything.
- ``removed``: kept for history; can't join new expenses or payments.

The account ``uid`` is private: it never appears in anything sent to a client.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from ..domain.errors import DomainError
from ..domain.money import MAX_ABS_MINOR_UNITS, is_valid_currency
from ..domain.room import CHARGE_KINDS, require_int, require_text, require_uuid
from .rules import ATTEMPT_STATES, parse_percent, settlement_plan

SCHEMA_VERSION = 1

CATEGORIES = ("food", "groceries", "housing", "utilities", "transport", "travel", "entertainment", "supplies", "other")
SPLIT_METHODS = ("equal", "exact", "percentage", "shares", "itemized")
PROVIDERS = ("appleCash", "paypal", "cashApp", "zelle", "venmo", "cash", "other")
GROUP_FIELDS = ("name", "details", "symbol", "currency")
EXPENSE_FIELDS = ("title", "amount", "date", "category", "payers", "split", "participants")

MAX_GROUP_NAME = 60
MAX_DETAILS = 140
MAX_SYMBOL = 64
MAX_MEMBER_NAME = 60
MAX_HANDLE = 30
MAX_TITLE = 120
MAX_NOTE = 280
MAX_REASON = 140
MAX_REFERENCE = 60
MAX_SEATS = 50
#: People with an account in the group at once (owner included). Joining beyond it is refused.
MAX_ACTIVE_MEMBERS = 25
MAX_SHARES_PER_EXPENSE = MAX_SEATS
MAX_EXPENSES = 2_000
MAX_ATTEMPTS = 2_000
#: Events kept inside the aggregate for cursor-based catch-up. Older cursors get a full snapshot.
RECENT_EVENTS = 300
#: Refuse growth well before Datastore's 1 MiB entity limit.
MAX_GROUP_BYTES = 900_000
MAX_RECEIPT_BYTES = 120_000


def group_bytes(group: dict[str, Any]) -> int:
    return len(json.dumps(group, separators=(",", ":")))


def require_iso_datetime(value: object, field_name: str) -> str:
    """An ISO 8601 timestamp from the client (display only; ordering always uses server time)."""
    if not isinstance(value, str) or not 10 <= len(value) <= 40:
        raise DomainError("invalid_payload", f"{field_name} must be an ISO 8601 date")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise DomainError("invalid_payload", f"{field_name} must be an ISO 8601 date") from error
    return value


def optional_text(value: object, field_name: str, max_length: int) -> str | None:
    if value is None:
        return None
    text = require_text(value, field_name, max_length=max_length, allow_empty=True)
    return text or None


def require_amount(value: object, field_name: str, *, allow_zero: bool = True) -> int:
    return require_int(value, field_name, low=0 if allow_zero else 1, high=MAX_ABS_MINOR_UNITS)


def require_currency(value: object) -> str:
    if not is_valid_currency(value):
        raise DomainError("invalid_payload", "currency must be an ISO 4217 code")
    return str(value)


def require_list(value: object, field_name: str, *, max_count: int) -> list[Any]:
    if not isinstance(value, list) or len(value) > max_count:
        raise DomainError("invalid_payload", f"{field_name} must be a list of at most {max_count}")
    return value


def require_dict(value: object, field_name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DomainError("invalid_payload", f"{field_name} must be an object")
    return value


def parse_shares(raw: object, field_name: str) -> list[dict[str, Any]]:
    shares: list[dict[str, Any]] = []
    for entry_value in require_list(raw, field_name, max_count=MAX_SHARES_PER_EXPENSE):
        entry = require_dict(entry_value, field_name)
        member = require_uuid(entry.get("memberId"), f"{field_name}.memberId")
        if any(share["memberId"] == member for share in shares):
            raise DomainError("invalid_payload", f"{field_name} lists someone twice")
        shares.append({"memberId": member, "amount": require_amount(entry.get("amount"), f"{field_name}.amount")})
    return shares


# MARK: - Groups and members


def find_member(group: dict[str, Any], member_id: str) -> dict[str, Any] | None:
    return next((member for member in group["members"] if member["id"] == member_id), None)


def member_for_uid(group: dict[str, Any], uid: str) -> dict[str, Any] | None:
    return next((member for member in group["members"] if member.get("uid") == uid and member["status"] == "active"), None)


def active_count(group: dict[str, Any]) -> int:
    """Members who joined with an account (the 25-person limit)."""
    return sum(1 for member in group["members"] if member["status"] == "active")


def member_ids(group: dict[str, Any]) -> list[str]:
    """Everyone who ever held a seat, in seat order (balances, plans, and history)."""
    return [member["id"] for member in group["members"]]


def participating_ids(group: dict[str, Any]) -> list[str]:
    """Seats that may appear in a new expense: active and pending."""
    return [member["id"] for member in group["members"] if member["status"] in ("active", "pending")]


def parse_group_fields(raw: dict[str, Any]) -> dict[str, Any]:
    symbol = require_text(raw.get("symbol", "person.3.fill"), "symbol", max_length=MAX_SYMBOL)
    if not all(character.isalnum() or character in ".-_" for character in symbol):
        raise DomainError("invalid_payload", "symbol must be an SF Symbol name")
    return {
        "name": require_text(raw.get("name"), "name", max_length=MAX_GROUP_NAME),
        "details": optional_text(raw.get("details"), "details", MAX_DETAILS),
        "symbol": symbol,
        "currency": require_currency(raw.get("currency")),
    }


def new_seat(member_id: str, display_name: object, now: str, *, uid: str | None, handle: object = None) -> dict[str, Any]:
    raw_handle = optional_text(handle, "handle", MAX_HANDLE)
    if raw_handle is not None and not all(character.isalnum() or character in "._-" for character in raw_handle):
        raise DomainError("invalid_payload", "handle may contain letters, digits, '.', '_', and '-'")
    return {
        "id": member_id,
        "displayName": require_text(display_name, "displayName", max_length=MAX_MEMBER_NAME),
        "handle": raw_handle.lower() if raw_handle else None,
        "status": "active" if uid else "pending",
        "uid": uid,
        "addedAt": now,
        "joinedAt": now if uid else None,
        "removedAt": None,
    }


def has_financial_records(group: dict[str, Any]) -> bool:
    return bool(group["expenses"] or group["settlements"] or group["attempts"])


# MARK: - Expenses


def parse_expense(raw: object, *, currency: str) -> dict[str, Any]:
    """Client input → the stored financial fields of one expense revision (not yet validated
    against the ledger; see ``rules.validate_expense``)."""
    raw = require_dict(raw, "expense")
    if raw.get("currency", currency) != currency:
        raise DomainError("currency_mismatch", "This group uses a different currency")
    category = raw.get("category", "other")
    if category not in CATEGORIES:
        raise DomainError("invalid_payload", "Unknown category")
    method = raw.get("splitMethod")
    if method not in SPLIT_METHODS:
        raise DomainError("invalid_payload", "Unknown split method")
    return {
        "id": require_uuid(raw.get("id"), "expense.id"),
        "title": require_text(raw.get("title"), "title", max_length=MAX_TITLE, allow_empty=True),
        "merchant": optional_text(raw.get("merchant"), "merchant", MAX_TITLE),
        "date": require_iso_datetime(raw.get("date"), "date"),
        "total": require_amount(raw.get("total"), "total"),
        "category": category,
        "splitMethod": method,
        "payments": parse_shares(raw.get("payments"), "payments"),
        "allocations": parse_shares(raw.get("allocations"), "allocations"),
        "note": optional_text(raw.get("note"), "note", MAX_NOTE),
    }


def parse_split(raw: object) -> dict[str, Any] | None:
    """How the client divided the total, so the server can recompute it (equal/shares/percentage)."""
    if raw is None:
        return None
    raw = require_dict(raw, "split")
    method = raw.get("method")
    if method == "equal":
        participants = [
            require_uuid(value, "split.participants")
            for value in require_list(raw.get("participants"), "split.participants", max_count=MAX_SEATS)
        ]
        return {"method": "equal", "participants": participants}
    if method == "shares":
        weights = []
        for entry_value in require_list(raw.get("weights"), "split.weights", max_count=MAX_SEATS):
            entry = require_dict(entry_value, "split.weights")
            weights.append(
                {
                    "memberId": require_uuid(entry.get("memberId"), "split.memberId"),
                    "weight": require_int(entry.get("weight"), "weight", low=0, high=1000),
                }
            )
        return {"method": "shares", "weights": weights}
    if method == "percentage":
        percentages = []
        for entry_value in require_list(raw.get("percentages"), "split.percentages", max_count=MAX_SEATS):
            entry = require_dict(entry_value, "split.percentages")
            percentages.append(
                {"memberId": require_uuid(entry.get("memberId"), "split.memberId"), "percent": parse_percent(entry.get("percent"))}
            )
        return {"method": "percentage", "percentages": percentages}
    raise DomainError("invalid_payload", "Unknown split method")


def revision_record(expense: dict[str, Any]) -> dict[str, Any]:
    """The financially meaningful fields of one revision (``ExpenseRevision`` in Swift)."""
    return {key: expense[key] for key in ("revision", "title", "total", "date", "category", "splitMethod", "payments", "allocations")}


def changed_fields(old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    """``ExpenseChangeSummary.changedFields`` (a note-only edit changes nothing financial)."""

    def as_set(shares: list[dict[str, Any]]) -> set[tuple[str, int]]:
        return {(share["memberId"], share["amount"]) for share in shares}

    fields: list[str] = []
    if old["title"] != new["title"] or old.get("merchant") != new.get("merchant"):
        fields.append("title")
    if old["total"] != new["total"]:
        fields.append("amount")
    if old["date"] != new["date"]:
        fields.append("date")
    if old["category"] != new["category"]:
        fields.append("category")
    if as_set(old["payments"]) != as_set(new["payments"]):
        fields.append("payers")
    old_members = {share["memberId"] for share in old["allocations"]}
    new_members = {share["memberId"] for share in new["allocations"]}
    if old_members != new_members:
        fields.append("participants")
    if old["splitMethod"] != new["splitMethod"] or (
        old_members == new_members and as_set(old["allocations"]) != as_set(new["allocations"])
    ):
        fields.append("split")
    return fields


# MARK: - Receipt snapshots


def _shares_of(raw: object, field_name: str, members: set[str]) -> list[dict[str, Any]]:
    shares = []
    for entry_value in require_list(raw, field_name, max_count=MAX_SEATS):
        entry = require_dict(entry_value, field_name)
        member = require_uuid(entry.get("memberId"), f"{field_name}.memberId")
        if member not in members:
            raise DomainError("invalid_receipt", "The receipt mentions someone who isn't in this group")
        shares.append(
            {
                "memberId": member,
                "amount": require_int(entry.get("amount"), f"{field_name}.amount", low=-MAX_ABS_MINOR_UNITS, high=MAX_ABS_MINOR_UNITS),
            }
        )
    return shares


def parse_receipt_snapshot(raw: object, expense: dict[str, Any], members: set[str]) -> dict[str, Any]:
    """The frozen item-level allocation behind an itemized expense (shown on both devices).

    Display data, but checked: bounded, every person is a seat, and the per-person totals equal
    the expense's allocations exactly, so the receipt can never disagree with the balance.
    """
    raw = require_dict(raw, "receipt")
    if len(json.dumps(raw, separators=(",", ":"))) > MAX_RECEIPT_BYTES:
        raise DomainError("payload_too_large", "This receipt is too large to share")
    items = []
    for entry_value in require_list(raw.get("items"), "receipt.items", max_count=300):
        entry = require_dict(entry_value, "receipt.items")
        items.append(
            {
                "id": require_uuid(entry.get("id"), "item.id"),
                "name": require_text(entry.get("name"), "item.name", max_length=MAX_TITLE, allow_empty=True),
                "quantity": None if entry.get("quantity") is None else require_int(entry.get("quantity"), "quantity", low=0, high=10_000),
                "lineTotal": require_int(entry.get("lineTotal"), "lineTotal", low=-MAX_ABS_MINOR_UNITS, high=MAX_ABS_MINOR_UNITS),
                "isRefund": bool(entry.get("isRefund", False)),
                "shares": _shares_of(entry.get("shares"), "item.shares", members),
            }
        )
    charges = []
    for entry_value in require_list(raw.get("charges"), "receipt.charges", max_count=40):
        entry = require_dict(entry_value, "receipt.charges")
        if entry.get("kind") not in CHARGE_KINDS:
            raise DomainError("invalid_payload", "Unknown charge kind")
        allocation = require_dict(entry.get("allocation", {"kind": "proportional"}), "charge.allocation")
        if len(json.dumps(allocation)) > 8_000:
            raise DomainError("payload_too_large", "This receipt is too large to share")
        charges.append(
            {
                "id": require_uuid(entry.get("id"), "charge.id"),
                "kind": entry["kind"],
                "label": require_text(entry.get("label"), "charge.label", max_length=60, allow_empty=True),
                "amount": require_int(entry.get("amount"), "charge.amount", low=-MAX_ABS_MINOR_UNITS, high=MAX_ABS_MINOR_UNITS),
                "allocation": allocation,
                "shares": _shares_of(entry.get("shares"), "charge.shares", members),
            }
        )
    participants: list[dict[str, Any]] = []
    for entry_value in require_list(raw.get("participants"), "receipt.participants", max_count=MAX_SEATS):
        entry = require_dict(entry_value, "receipt.participants")
        member = require_uuid(entry.get("memberId"), "participant.memberId")
        if member not in members:
            raise DomainError("invalid_receipt", "The receipt mentions someone who isn't in this group")
        parts = {
            key: require_int(entry.get(key, 0), key, low=-MAX_ABS_MINOR_UNITS, high=MAX_ABS_MINOR_UNITS)
            for key in ("items", "tax", "tip", "fees", "discounts", "adjustments")
        }
        total = require_int(entry.get("total"), "participant.total", low=-MAX_ABS_MINOR_UNITS, high=MAX_ABS_MINOR_UNITS)
        if sum(parts.values()) != total:
            raise DomainError("invalid_receipt", "A person's receipt total doesn't add up")
        participants.append({"memberId": member, **parts, "total": total})
    rounding = []
    for entry_value in require_list(raw.get("rounding", []), "receipt.rounding", max_count=400):
        entry = require_dict(entry_value, "receipt.rounding")
        source_kind = entry.get("sourceKind")
        if source_kind not in ("item", "charge"):
            raise DomainError("invalid_payload", "Unknown rounding source")
        member = require_uuid(entry.get("memberId"), "rounding.memberId")
        if member not in members:
            raise DomainError("invalid_receipt", "The receipt mentions someone who isn't in this group")
        rounding.append(
            {
                "sourceKind": source_kind,
                "sourceId": require_uuid(entry.get("sourceId"), "rounding.sourceId"),
                "memberId": member,
                "amount": require_int(entry.get("amount"), "rounding.amount", low=-1000, high=1000),
            }
        )
    snapshot = {
        "merchant": require_text(raw.get("merchant"), "receipt.merchant", max_length=MAX_TITLE, allow_empty=True),
        "date": require_iso_datetime(raw.get("date"), "receipt.date"),
        "total": require_amount(raw.get("total"), "receipt.total"),
        "items": items,
        "charges": charges,
        "participants": participants,
        "rounding": rounding,
    }
    if snapshot["total"] != expense["total"]:
        raise DomainError("invalid_receipt", "The receipt total doesn't match the expense")
    by_member: dict[str, int] = {}
    for participant in participants:
        member_key = str(participant["memberId"])
        by_member[member_key] = by_member.get(member_key, 0) + int(participant["total"])
    allocated = {share["memberId"]: share["amount"] for share in expense["allocations"] if share["amount"] != 0}
    if {member: units for member, units in by_member.items() if units != 0} != allocated:
        raise DomainError("invalid_receipt", "The receipt split doesn't match the expense")
    return snapshot


# MARK: - What a member sees


def member_view(member: dict[str, Any], destination_providers: list[str] | None) -> dict[str, Any]:
    return {
        "id": member["id"],
        "displayName": member["displayName"],
        "handle": member.get("handle"),
        "status": member["status"],
        "hasAccount": member.get("uid") is not None,
        "addedAt": member["addedAt"],
        "joinedAt": member.get("joinedAt"),
        "removedAt": member.get("removedAt"),
        # Provider names only. Identifiers are revealed separately, to someone who owes this person.
        "destinationProviders": destination_providers or [],
    }


def attempt_view(attempt: dict[str, Any], viewer: str) -> dict[str, Any]:
    """Free-text notes (reasons, references) are visible only to the two people in the payment."""
    involved = viewer in (attempt["payerId"], attempt["recipientId"])
    view = {key: value for key, value in attempt.items() if key not in ("history", "externalReference")}
    view["history"] = [{**entry, "note": entry.get("note") if involved else None} for entry in attempt["history"]]
    view["externalReference"] = attempt.get("externalReference") if involved else None
    return view


def balances_view(group: dict[str, Any]) -> dict[str, Any]:
    plan = settlement_plan(member_ids(group), group["expenses"], group["settlements"], group["attempts"], bool(group["simplifiesDebts"]))
    return plan.to_wire()


def header_view(group: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": group["id"],
        "name": group["name"],
        "details": group.get("details"),
        "symbol": group["symbol"],
        "currency": group["currency"],
        "simplifiesDebts": group["simplifiesDebts"],
        "ownerMemberId": group["ownerMemberId"],
        "createdAt": group["createdAt"],
        "archivedAt": group.get("archivedAt"),
        "revision": group["revision"],
        "publishedFromDevice": group.get("publicationId") is not None,
    }


def validate_attempt_state(state: object) -> str:
    if state not in ATTEMPT_STATES:
        raise DomainError("invalid_payload", "Unknown payment state")
    return str(state)
