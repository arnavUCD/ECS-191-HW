"""Receipt Room domain model and its versioned wire format (API v1).

This mirrors the Swift `ReceiptRoom`/`ReceiptDraft` models. Every money value is an ``int`` in
minor units of the room's currency. Identifiers are lowercase UUID strings. The wire format is
documented in ``server/API.md`` and decoded by the iOS `RemoteRoomDTO` types.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from .errors import DomainError

ROOM_STATES = ("draft", "ready", "open", "resolving", "readyToFinalize", "finalized", "cancelled")
TERMINAL_STATES = ("finalized", "cancelled")
CHARGE_KINDS = ("tax", "tip", "serviceCharge", "fee", "discount", "adjustment")
ALLOCATION_KINDS = ("proportional", "equal", "shares", "exact", "payer")
#: ``units``: a whole number of the line's printed quantity ("2 of the 3 beers").
CLAIM_MODES = ("full", "equalShare", "shares", "exact", "units")
PARTICIPANT_KINDS = ("host", "member", "guest")
#: ``group``: a Live Receipt Room published from a group (milestone 4). ``temporary``: "Split with
#: people now" — no group; guests join by invitation and settle up with the payer in the room.
#: ``groupReceipt``: a receipt posted into a shared group for asynchronous allocation. It is stored
#: with its group and never reachable through room routes, invitations, or guest credentials.
ROOM_KINDS = ("group", "temporary", "groupReceipt")
#: Why a temporary room ended: everyone paid and was confirmed, the host cancelled, or it expired.
END_REASONS = ("allSquare", "cancelled", "expired")

MAX_ITEMS = 300
MAX_CHARGES = 40
MAX_PARTICIPANTS = 60
MAX_NAME = 120
MAX_LABEL = 60
MAX_NOTE = 140
MAX_DISPLAY_NAME = 40
MAX_SHARE_WEIGHT = 1000
#: Largest printed quantity that can be claimed unit by unit.
MAX_UNITS = 10_000


def new_id() -> str:
    return str(uuid.uuid4())


def require_uuid(value: object, field_name: str) -> str:
    if not isinstance(value, str):
        raise DomainError("invalid_payload", f"{field_name} must be a string identifier")
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise DomainError("invalid_payload", f"{field_name} must be a UUID") from error


def require_int(value: object, field_name: str, *, low: int, high: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise DomainError("invalid_payload", f"{field_name} must be an integer")
    if value < low or value > high:
        raise DomainError("invalid_payload", f"{field_name} is out of range")
    return value


def require_text(value: object, field_name: str, *, max_length: int, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise DomainError("invalid_payload", f"{field_name} must be text")
    text = " ".join(value.split())
    if not allow_empty and not text:
        raise DomainError("invalid_payload", f"{field_name} is required")
    if len(text) > max_length:
        raise DomainError("invalid_payload", f"{field_name} is too long")
    return text


def optional_note(value: object) -> str | None:
    if value is None:
        return None
    text = require_text(value, "note", max_length=10_000, allow_empty=True)
    if len(text) > MAX_NOTE:
        raise DomainError("note_too_long", "Keep the note under 140 characters")
    return text or None


@dataclass
class Item:
    id: str
    name: str
    line_total: int
    quantity: int | None = None
    unit_price: int | None = None
    is_refund: bool = False

    @property
    def is_note(self) -> bool:
        return self.line_total == 0

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "lineTotal": self.line_total,
            "quantity": self.quantity,
            "unitPrice": self.unit_price,
            "isRefund": self.is_refund,
        }


@dataclass
class ChargeAllocation:
    kind: str = "proportional"
    #: ``equal``: explicit recipients, or ``None`` for everyone in the room.
    members: list[str] | None = None
    #: ``shares``: (participant, weight) in the order given.
    weights: list[tuple[str, int]] = field(default_factory=list)
    #: ``exact``: (participant, amount) in the order given.
    amounts: list[tuple[str, int]] = field(default_factory=list)

    def to_wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {"kind": self.kind}
        if self.kind == "equal":
            wire["members"] = self.members
        if self.kind == "shares":
            wire["weights"] = [{"participantId": pid, "weight": weight} for pid, weight in self.weights]
        if self.kind == "exact":
            wire["amounts"] = [{"participantId": pid, "amount": amount} for pid, amount in self.amounts]
        return wire

    @staticmethod
    def from_wire(raw: object, max_amount: int) -> ChargeAllocation:
        if not isinstance(raw, dict) or raw.get("kind") not in ALLOCATION_KINDS:
            raise DomainError("invalid_payload", "allocation.kind is invalid")
        kind = raw["kind"]
        if kind == "equal":
            members = raw.get("members")
            if members is None:
                return ChargeAllocation("equal", None)
            if not isinstance(members, list) or len(members) > MAX_PARTICIPANTS:
                raise DomainError("invalid_payload", "allocation.members is invalid")
            return ChargeAllocation("equal", [require_uuid(m, "allocation.members") for m in members])
        if kind == "shares":
            weights = raw.get("weights")
            if not isinstance(weights, list) or len(weights) > MAX_PARTICIPANTS:
                raise DomainError("invalid_payload", "allocation.weights is invalid")
            parsed = [
                (
                    require_uuid(w.get("participantId") if isinstance(w, dict) else None, "participantId"),
                    require_int(w.get("weight") if isinstance(w, dict) else None, "weight", low=0, high=MAX_SHARE_WEIGHT),
                )
                for w in weights
            ]
            return ChargeAllocation("shares", weights=parsed)
        if kind == "exact":
            amounts = raw.get("amounts")
            if not isinstance(amounts, list) or len(amounts) > MAX_PARTICIPANTS:
                raise DomainError("invalid_payload", "allocation.amounts is invalid")
            parsed_amounts = [
                (
                    require_uuid(a.get("participantId") if isinstance(a, dict) else None, "participantId"),
                    require_int(a.get("amount") if isinstance(a, dict) else None, "amount", low=-max_amount, high=max_amount),
                )
                for a in amounts
            ]
            return ChargeAllocation("exact", amounts=parsed_amounts)
        return ChargeAllocation(kind)


@dataclass
class Charge:
    id: str
    kind: str
    label: str
    amount: int
    allocation: ChargeAllocation = field(default_factory=ChargeAllocation)

    @property
    def sign(self) -> int:
        if self.kind == "discount":
            return -1
        if self.kind == "adjustment":
            return 0
        return 1

    def to_wire(self) -> dict[str, Any]:
        return {"id": self.id, "kind": self.kind, "label": self.label, "amount": self.amount, "allocation": self.allocation.to_wire()}


@dataclass
class Receipt:
    merchant: str
    date: str
    currency: str
    items: list[Item]
    charges: list[Charge]
    total: int | None
    subtotal: int | None = None

    def item(self, item_id: str) -> Item | None:
        return next((item for item in self.items if item.id == item_id), None)

    def charge(self, charge_id: str) -> Charge | None:
        return next((charge for charge in self.charges if charge.id == charge_id), None)

    def to_wire(self) -> dict[str, Any]:
        return {
            "merchant": self.merchant,
            "date": self.date,
            "currency": self.currency,
            "total": self.total,
            "subtotal": self.subtotal,
            "items": [item.to_wire() for item in self.items],
            "charges": [charge.to_wire() for charge in self.charges],
        }


@dataclass
class ClaimMode:
    kind: str
    shares: int | None = None
    amount: int | None = None
    #: ``units``: how many of the line's printed quantity this person had.
    units: int | None = None

    def to_wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {"kind": self.kind}
        if self.kind == "shares":
            wire["shares"] = self.shares
        if self.kind == "exact":
            wire["amount"] = self.amount
        if self.kind == "units":
            wire["units"] = self.units
        return wire

    def key(self) -> str:
        return f"{self.kind}:{self.shares}:{self.amount}:{self.units}"


@dataclass
class Claim:
    item_id: str
    participant_id: str
    mode: ClaimMode

    def to_wire(self) -> dict[str, Any]:
        return {"itemId": self.item_id, "participantId": self.participant_id, "mode": self.mode.to_wire()}


@dataclass
class Dispute:
    id: str
    target_kind: str  # "item" | "charge"
    target_id: str
    raised_by: str
    note: str | None
    created_at: str
    status: str = "open"  # open | resolved | dismissed
    resolved_by: str | None = None
    resolved_at: str | None = None
    resolution_note: str | None = None

    @property
    def is_open(self) -> bool:
        return self.status == "open"

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "target": {"kind": self.target_kind, "id": self.target_id},
            "raisedBy": self.raised_by,
            "note": self.note,
            "createdAt": self.created_at,
            "status": self.status,
            "resolvedBy": self.resolved_by,
            "resolvedAt": self.resolved_at,
            "resolutionNote": self.resolution_note,
        }


@dataclass
class Participant:
    id: str
    display_name: str
    kind: str  # host | member | guest
    joined_at: str
    removed_at: str | None = None
    #: The account (Firebase uid) or guest credential bound to this seat. Never sent to clients.
    bound_subject: str | None = None
    #: True once someone has joined as this seat (members start unbound until claimed).
    account_backed: bool = False

    @property
    def is_active(self) -> bool:
        return self.removed_at is None

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "displayName": self.display_name,
            "kind": self.kind,
            "joinedAt": self.joined_at,
            "removed": self.removed_at is not None,
            "isClaimedSeat": self.bound_subject is not None,
            "accountBacked": self.account_backed,
        }


@dataclass
class HistoryEntry:
    sequence: int
    revision: int
    actor_id: str
    at: str
    type: str
    detail: dict[str, Any] = field(default_factory=dict)

    def to_wire(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "revision": self.revision,
            "actorId": self.actor_id,
            "at": self.at,
            "type": self.type,
            "detail": self.detail,
        }


@dataclass
class Finalization:
    finalized_at: str
    finalized_by: str
    revision: int
    participants: list[dict[str, Any]]
    items: list[dict[str, Any]]
    charges: list[dict[str, Any]]
    rounding: list[dict[str, Any]]
    payments: list[dict[str, Any]]
    total: int
    #: People whose share the host finalized without their review, after acknowledging each one.
    host_resolved: list[str] = field(default_factory=list)

    def to_wire(self) -> dict[str, Any]:
        return {
            "finalizedAt": self.finalized_at,
            "finalizedBy": self.finalized_by,
            "revision": self.revision,
            "participants": self.participants,
            "items": self.items,
            "charges": self.charges,
            "rounding": self.rounding,
            "payments": self.payments,
            "total": self.total,
            "hostResolved": self.host_resolved,
        }


@dataclass
class Room:
    id: str
    host_uid: str
    host_participant_id: str
    payer_id: str | None
    state: str
    receipt: Receipt
    participants: list[Participant]
    claims: list[Claim] = field(default_factory=list)
    disputes: list[Dispute] = field(default_factory=list)
    reviews: dict[str, int] = field(default_factory=dict)
    needs_review: list[str] = field(default_factory=list)
    payer_accepts_full_receipt: bool = False
    revision: int = 1
    history: list[HistoryEntry] = field(default_factory=list)
    created_at: str = ""
    updated_at: str = ""
    finalization: Finalization | None = None
    asset_ids: list[str] = field(default_factory=list)
    kind: str = "group"
    #: Each participant's total when they last marked their share reviewed. A review counts only
    #: while the share is unchanged (someone sharing your item afterwards makes it unreviewed).
    review_totals: dict[str, int] = field(default_factory=dict)
    #: Temporary rooms: when claiming (before finalization) or paying (after) stops.
    expires_at: str | None = None
    #: Temporary rooms: when the room ended and why. A read-only summary remains for a while.
    closed_at: str | None = None
    end_reason: str | None = None
    #: Temporary rooms: what each participant owes the payer after finalization, and how it's going.
    payments: list[dict[str, Any]] = field(default_factory=list)
    #: Temporary rooms: the host's payment destinations, shown only to people who owe them.
    destination_ids: list[str] = field(default_factory=list)
    #: Group receipts: the shared group the receipt belongs to.
    group_id: str | None = None

    @property
    def is_temporary(self) -> bool:
        return self.kind == "temporary"

    @property
    def requires_reviews(self) -> bool:
        """Finalizing someone's unreviewed share needs the host's explicit acknowledgement."""
        return self.kind in ("temporary", "groupReceipt")

    @property
    def participant_ids(self) -> list[str]:
        """Active participants in room order (host first, then seats, then guests)."""
        return [p.id for p in self.participants if p.is_active]

    @property
    def open_disputes(self) -> list[Dispute]:
        return [d for d in self.disputes if d.is_open]

    def participant(self, participant_id: str) -> Participant | None:
        return next((p for p in self.participants if p.id == participant_id), None)

    def claims_for(self, item_id: str) -> list[Claim]:
        return [c for c in self.claims if c.item_id == item_id]

    def claim(self, item_id: str, participant_id: str) -> Claim | None:
        return next((c for c in self.claims if c.item_id == item_id and c.participant_id == participant_id), None)
