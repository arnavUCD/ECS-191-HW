"""Validated parsing of client payloads and (de)serialization of rooms for storage and clients.

Every client value is untrusted: types, lengths, counts, identifiers, and monetary bounds are
checked before anything reaches the engine.
"""

from __future__ import annotations

import re
from typing import Any

from .allocation import allocate
from .errors import DomainError
from .money import MAX_ABS_MINOR_UNITS, is_valid_currency
from .readiness import readiness_issues, unreviewed_participants
from .room import (
    CHARGE_KINDS,
    CLAIM_MODES,
    MAX_CHARGES,
    MAX_ITEMS,
    MAX_LABEL,
    MAX_NAME,
    MAX_UNITS,
    Charge,
    ChargeAllocation,
    Claim,
    ClaimMode,
    Dispute,
    Finalization,
    HistoryEntry,
    Item,
    Participant,
    Receipt,
    Room,
    require_int,
    require_text,
    require_uuid,
)

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def receipt_from_wire(raw: object, max_amount: int = MAX_ABS_MINOR_UNITS) -> Receipt:
    if not isinstance(raw, dict):
        raise DomainError("invalid_payload", "receipt must be an object")
    currency = raw.get("currency")
    if not isinstance(currency, str) or not is_valid_currency(currency):
        raise DomainError("invalid_payload", "receipt.currency must be an ISO 4217 code")
    date = raw.get("date")
    if not isinstance(date, str) or not _DATE.match(date):
        raise DomainError("invalid_payload", "receipt.date must be YYYY-MM-DD")
    merchant = require_text(raw.get("merchant", ""), "receipt.merchant", max_length=MAX_NAME, allow_empty=True)
    items_raw = raw.get("items")
    charges_raw = raw.get("charges", [])
    if not isinstance(items_raw, list) or len(items_raw) > MAX_ITEMS:
        raise DomainError("invalid_payload", "receipt.items is invalid or too long")
    if not isinstance(charges_raw, list) or len(charges_raw) > MAX_CHARGES:
        raise DomainError("invalid_payload", "receipt.charges is invalid or too long")
    items: list[Item] = []
    seen: set[str] = set()
    for entry in items_raw:
        if not isinstance(entry, dict):
            raise DomainError("invalid_payload", "receipt.items entries must be objects")
        item_id = require_uuid(entry.get("id"), "item.id")
        if item_id in seen:
            raise DomainError("invalid_payload", "Duplicate item identifier")
        seen.add(item_id)
        quantity = entry.get("quantity")
        unit_price = entry.get("unitPrice")
        is_refund = entry.get("isRefund", False)
        if not isinstance(is_refund, bool):
            raise DomainError("invalid_payload", "item.isRefund must be true or false")
        items.append(
            Item(
                id=item_id,
                name=require_text(entry.get("name", ""), "item.name", max_length=MAX_NAME, allow_empty=True),
                line_total=require_int(entry.get("lineTotal"), "item.lineTotal", low=-max_amount, high=max_amount),
                quantity=None if quantity is None else require_int(quantity, "item.quantity", low=-1000, high=10_000),
                unit_price=None if unit_price is None else require_int(unit_price, "item.unitPrice", low=-max_amount, high=max_amount),
                is_refund=is_refund,
            )
        )
    charges: list[Charge] = []
    for entry in charges_raw:
        if not isinstance(entry, dict):
            raise DomainError("invalid_payload", "receipt.charges entries must be objects")
        charge_id = require_uuid(entry.get("id"), "charge.id")
        if charge_id in seen:
            raise DomainError("invalid_payload", "Duplicate charge identifier")
        seen.add(charge_id)
        kind = entry.get("kind")
        if kind not in CHARGE_KINDS:
            raise DomainError("invalid_payload", "charge.kind is invalid")
        allocation_raw = entry.get("allocation", {"kind": "proportional"})
        charges.append(
            Charge(
                id=charge_id,
                kind=kind,
                label=require_text(entry.get("label", ""), "charge.label", max_length=MAX_LABEL, allow_empty=True),
                amount=require_int(entry.get("amount"), "charge.amount", low=-max_amount, high=max_amount),
                allocation=ChargeAllocation.from_wire(allocation_raw, max_amount),
            )
        )
    total = raw.get("total")
    subtotal = raw.get("subtotal")
    return Receipt(
        merchant=merchant,
        date=date,
        currency=currency,
        items=items,
        charges=charges,
        total=None if total is None else require_int(total, "receipt.total", low=-max_amount, high=max_amount),
        subtotal=None if subtotal is None else require_int(subtotal, "receipt.subtotal", low=-max_amount, high=max_amount),
    )


def claim_mode_from_wire(raw: object, max_amount: int) -> ClaimMode:
    if not isinstance(raw, dict) or raw.get("kind") not in CLAIM_MODES:
        raise DomainError("invalid_payload", "claim.mode is invalid")
    kind = raw["kind"]
    if kind == "shares":
        return ClaimMode("shares", shares=require_int(raw.get("shares"), "mode.shares", low=0, high=1000))
    if kind == "exact":
        return ClaimMode("exact", amount=require_int(raw.get("amount"), "mode.amount", low=-max_amount, high=max_amount))
    if kind == "units":
        return ClaimMode("units", units=require_int(raw.get("units"), "mode.units", low=1, high=MAX_UNITS))
    return ClaimMode(kind)


# MARK: - Storage (complete, including server-only fields)


def room_to_storage(room: Room) -> dict[str, Any]:
    return {
        "id": room.id,
        "hostUid": room.host_uid,
        "hostParticipantId": room.host_participant_id,
        "payerId": room.payer_id,
        "state": room.state,
        "receipt": room.receipt.to_wire(),
        "participants": [{**p.to_wire(), "boundSubject": p.bound_subject, "removedAt": p.removed_at} for p in room.participants],
        "claims": [c.to_wire() for c in room.claims],
        "disputes": [d.to_wire() for d in room.disputes],
        "reviews": room.reviews,
        "needsReview": room.needs_review,
        "payerAcceptsFullReceipt": room.payer_accepts_full_receipt,
        "revision": room.revision,
        "history": [h.to_wire() for h in room.history],
        "createdAt": room.created_at,
        "updatedAt": room.updated_at,
        "finalization": room.finalization.to_wire() if room.finalization else None,
        "assetIds": room.asset_ids,
        "kind": room.kind,
        "reviewTotals": room.review_totals,
        "expiresAt": room.expires_at,
        "closedAt": room.closed_at,
        "endReason": room.end_reason,
        "payments": room.payments,
        "destinationIds": room.destination_ids,
        "groupId": room.group_id,
    }


def room_from_storage(raw: dict[str, Any]) -> Room:
    receipt = receipt_from_wire(raw["receipt"])
    participants = [
        Participant(
            id=p["id"],
            display_name=p["displayName"],
            kind=p["kind"],
            joined_at=p["joinedAt"],
            removed_at=p.get("removedAt"),
            bound_subject=p.get("boundSubject"),
            account_backed=p.get("accountBacked", False),
        )
        for p in raw["participants"]
    ]
    claims = [Claim(c["itemId"], c["participantId"], claim_mode_from_wire(c["mode"], MAX_ABS_MINOR_UNITS)) for c in raw["claims"]]
    disputes = [
        Dispute(
            id=d["id"],
            target_kind=d["target"]["kind"],
            target_id=d["target"]["id"],
            raised_by=d["raisedBy"],
            note=d.get("note"),
            created_at=d["createdAt"],
            status=d["status"],
            resolved_by=d.get("resolvedBy"),
            resolved_at=d.get("resolvedAt"),
            resolution_note=d.get("resolutionNote"),
        )
        for d in raw["disputes"]
    ]
    history = [
        HistoryEntry(h["sequence"], h["revision"], h["actorId"], h["at"], h["type"], h.get("detail", {})) for h in raw.get("history", [])
    ]
    final = raw.get("finalization")
    finalization = (
        None
        if final is None
        else Finalization(
            finalized_at=final["finalizedAt"],
            finalized_by=final["finalizedBy"],
            revision=final["revision"],
            participants=final["participants"],
            items=final["items"],
            charges=final["charges"],
            rounding=final["rounding"],
            payments=final["payments"],
            total=final["total"],
            host_resolved=list(final.get("hostResolved", [])),
        )
    )
    return Room(
        id=raw["id"],
        host_uid=raw["hostUid"],
        host_participant_id=raw["hostParticipantId"],
        payer_id=raw.get("payerId"),
        state=raw["state"],
        receipt=receipt,
        participants=participants,
        claims=claims,
        disputes=disputes,
        reviews={k: int(v) for k, v in raw.get("reviews", {}).items()},
        needs_review=list(raw.get("needsReview", [])),
        payer_accepts_full_receipt=bool(raw.get("payerAcceptsFullReceipt", False)),
        revision=int(raw["revision"]),
        history=history,
        created_at=raw.get("createdAt", ""),
        updated_at=raw.get("updatedAt", ""),
        finalization=finalization,
        asset_ids=list(raw.get("assetIds", [])),
        kind=raw.get("kind", "group"),
        review_totals={k: int(v) for k, v in raw.get("reviewTotals", {}).items()},
        expires_at=raw.get("expiresAt"),
        closed_at=raw.get("closedAt"),
        end_reason=raw.get("endReason"),
        payments=list(raw.get("payments", [])),
        destination_ids=list(raw.get("destinationIds", [])),
        group_id=raw.get("groupId"),
    )


# MARK: - Client snapshot


def payments_view(room: Room, viewer_participant_id: str, viewer_is_host: bool) -> list[dict[str, Any]]:
    """The host (who receives every payment) sees all of them; anyone else sees only their own."""
    return [payment for payment in room.payments if viewer_is_host or payment["participantId"] == viewer_participant_id]


def room_snapshot(room: Room, viewer_participant_id: str, viewer_is_host: bool, *, expired: bool = False) -> dict[str, Any]:
    """What a participant may see. Never includes credentials, account identifiers, or tokens.

    ``expired``: a temporary room whose deadline passed but which the cleanup job hasn't closed
    yet. It reads exactly like a closed one."""
    allocation = allocate(room)
    closed_at = room.closed_at or (room.expires_at if expired else None)
    end_reason = room.end_reason or ("expired" if expired else None)
    return {
        "roomId": room.id,
        "revision": room.revision,
        "state": room.state,
        "hostParticipantId": room.host_participant_id,
        "payerId": room.payer_id,
        "receipt": room.receipt.to_wire(),
        "participants": [p.to_wire() for p in room.participants],
        "participantOrder": room.participant_ids,
        "claims": [c.to_wire() for c in room.claims],
        "disputes": [d.to_wire() for d in room.disputes],
        "reviews": [{"participantId": pid, "revision": rev} for pid, rev in room.reviews.items()],
        "needsReview": room.needs_review,
        "payerAcceptsFullReceipt": room.payer_accepts_full_receipt,
        "allocation": allocation.to_wire(),
        "readiness": readiness_issues(room, allocation),
        "finalization": room.finalization.to_wire() if room.finalization else None,
        "assets": [{"id": asset_id} for asset_id in room.asset_ids],
        "viewer": {"participantId": viewer_participant_id, "isHost": viewer_is_host},
        "updatedAt": room.updated_at,
        "kind": room.kind,
        "unreviewed": unreviewed_participants(room, allocation),
        "expiresAt": room.expires_at,
        "closedAt": closed_at,
        "endReason": end_reason,
        "payments": payments_view(room, viewer_participant_id, viewer_is_host),
        "paymentDestinationCount": len(room.destination_ids),
    }
