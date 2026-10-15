"""Receipts posted into a shared group for asynchronous allocation ("Add to a group").

A host posts a reviewed receipt to a shared group with the members who were there. It's a
*pending receipt allocation*: those members claim items on their own devices whenever they like,
review their estimated share, and dispute what's wrong; the host assigns, resolves, and finally
turns it into exactly one itemized group expense. There's no live room, invitation, short code, or
guest access: only active members of the group who were selected can see the details or act.

The allocation rules are the receipt room's (``domain.engine``) applied to a ``groupReceipt`` record
whose participants are the selected members (participant ID = member ID). Every change is a group
command, so it shares the group's idempotency, transaction, event history, and sync: a change
emits a group event naming the receipt, and the group's snapshot and change pages carry the
receipt to everyone allowed to see it. Until it's finalized, a pending receipt is never part of
balances, the settlement plan, or payment obligations — those come from expenses only.
"""

from __future__ import annotations

import json
from typing import Any

from ..domain.engine import Actor, apply_command
from ..domain.errors import DomainError
from ..domain.money import MAX_ABS_MINOR_UNITS
from ..domain.readiness import receipt_blocking_issues, unreviewed_participants
from ..domain.room import TERMINAL_STATES, HistoryEntry, Participant, Room, require_int, require_uuid
from ..domain.wire import receipt_from_wire, room_from_storage, room_to_storage
from . import group as model

#: Receipts waiting for allocation in one group at once.
MAX_OPEN_RECEIPTS = 20
#: Refuse growth well before Datastore's 1 MiB entity limit (same ceiling as a room).
MAX_RECEIPT_RECORD_BYTES = 900_000
#: Receipt-room commands a member may send through ``receiptCommand`` (finalizing has its own command).
RECEIPT_COMMANDS = frozenset(
    {
        "claim",
        "unclaim",
        "claimUnits",
        "setItemSplit",
        "dispute",
        "markReviewed",
        "resolveDispute",
        "setChargeAllocation",
        "reviseReceipt",
        "setPayerAcceptsFullReceipt",
        "removeParticipant",
        "transition",
    }
)


def summary(room: Room) -> dict[str, Any]:
    """What the group document keeps about one receipt: enough for lists, attention, and rules
    about leaving the group, without loading the receipt itself."""
    return {
        "id": room.id,
        "state": room.state,
        "hostMemberId": room.host_participant_id,
        "payerId": room.payer_id,
        "participantIds": room.participant_ids,
        "merchant": room.receipt.merchant,
        "date": room.receipt.date,
        "currency": room.receipt.currency,
        "total": room.receipt.total,
        "revision": room.revision,
        "createdAt": room.created_at,
        "updatedAt": room.updated_at,
        "unreviewed": [] if room.state in TERMINAL_STATES else unreviewed_participants(room),
        "expenseId": room.id if room.state == "finalized" else None,
    }


def open_receipts(group: dict[str, Any]) -> list[dict[str, Any]]:
    return [entry for entry in group.get("receipts", []) if entry["state"] not in TERMINAL_STATES]


def has_open_receipt(group: dict[str, Any], member_id: str) -> bool:
    return any(member_id in entry["participantIds"] for entry in open_receipts(group))


class ReceiptAccess:
    """Loads and stores receipts for one command (``Context`` provides the loader and the outcome)."""

    def __init__(self, context: Any) -> None:
        self.context = context

    def load(self, receipt_id: str) -> Room:
        record = self.context.outcome.receipts.get(receipt_id) or self.context.load_receipt(receipt_id)
        if record is None or not any(entry["id"] == receipt_id for entry in self.context.group.get("receipts", [])):
            raise DomainError("receipt_not_found", "That receipt isn't in this group")
        return room_from_storage(record)

    def store(self, room: Room) -> None:
        stored = room_to_storage(room)
        if len(json.dumps(stored, separators=(",", ":"))) > MAX_RECEIPT_RECORD_BYTES:
            raise DomainError("payload_too_large", "This receipt has reached its size limit")
        self.context.outcome.receipts[room.id] = stored
        entries: list[dict[str, Any]] = self.context.group.setdefault("receipts", [])
        entry = summary(room)
        for index, existing in enumerate(entries):
            if existing["id"] == room.id:
                entries[index] = entry
                return
        entries.append(entry)


def _title(room: Room) -> str:
    return room.receipt.merchant or "Receipt"


def post_receipt(context: Any, payload: dict[str, Any]) -> None:
    """Posts a reviewed receipt with the members who were there. Doesn't need item assignment."""
    group = context.group
    receipt_id = require_uuid(payload.get("receiptId"), "receiptId")
    existing = next((entry for entry in group.get("receipts", []) if entry["id"] == receipt_id), None)
    if existing is not None:
        if existing["hostMemberId"] != context.actor_id:
            raise DomainError("entity_exists", "That receipt already exists")
        context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": existing["revision"]})
        return  # posting again (a retry from another session) changes nothing
    receipt = receipt_from_wire(payload.get("receipt"))
    issues = receipt_blocking_issues(receipt)
    if issues:
        raise DomainError("receipt_not_ready", "Finish reviewing the receipt first", {"issues": issues})
    if receipt.currency != group["currency"]:
        raise DomainError("currency_mismatch", "This receipt uses a different currency than the group")
    if len(open_receipts(group)) >= MAX_OPEN_RECEIPTS:
        raise DomainError("receipt_limit", "This group has too many receipts waiting. Finish one first", {"limit": MAX_OPEN_RECEIPTS})
    chosen: list[str] = []
    for value in model.require_list(payload.get("participantIds"), "participantIds", max_count=model.MAX_SEATS):
        member_id = require_uuid(value, "participantIds")
        if member_id not in chosen:
            chosen.append(member_id)
    if context.actor_id not in chosen:
        chosen.insert(0, context.actor_id)
    # The host first, then everyone else in the group's own order.
    ordered = [context.actor_id] + [
        member["id"] for member in group["members"] if member["id"] in chosen and member["id"] != context.actor_id
    ]
    for member_id in chosen:
        member = model.find_member(group, member_id)
        if member is None or member["status"] != "active":
            raise DomainError("inactive_participant", "Choose people who have joined the group", {"memberId": member_id})
    payer_id = require_uuid(payload.get("payerId", context.actor_id), "payerId")
    if payer_id not in ordered:
        raise DomainError("participant_not_in_room", "The payer must be one of the people on this receipt")
    now = context.now
    participants = []
    for member_id in ordered:
        member = model.find_member(group, member_id)
        participants.append(
            Participant(
                id=member_id,
                display_name=str(member["displayName"]) if member else "",
                kind="host" if member_id == context.actor_id else "member",
                joined_at=now,
                bound_subject=f"member:{member_id}",
                account_backed=True,
            )
        )
    room = Room(
        id=receipt_id,
        host_uid=context.actor_uid,
        host_participant_id=context.actor_id,
        payer_id=payer_id,
        state="open",
        receipt=receipt,
        participants=participants,
        revision=1,
        history=[HistoryEntry(1, 1, context.actor_id, now, "published", {})],
        created_at=now,
        updated_at=now,
        kind="groupReceipt",
        group_id=group["id"],
    )
    ReceiptAccess(context).store(room)
    context.outcome.touched_receipts.add(receipt_id)
    context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": room.revision})
    context.event(
        "receiptPosted",
        {"receiptId": receipt_id, "title": _title(room), "total": receipt.total, "participantIds": ordered, "payerId": payer_id},
    )


def _actor(room: Room, context: Any) -> Actor:
    """Only the members selected for this receipt (still on it) may act on it."""
    participant = room.participant(context.actor_id)
    if participant is None or not participant.is_active:
        raise DomainError("not_a_participant", "Only the people on this receipt can change it")
    return Actor(context.actor_id, is_host=context.actor_id == room.host_participant_id)


def _expected(payload: dict[str, Any]) -> int:
    return require_int(payload.get("expectedRevision"), "expectedRevision", low=0, high=10_000_000)


def _conflict(room: Room) -> DomainError:
    return DomainError(
        "receipt_conflict",
        "Someone changed this receipt first. Review the latest and try again",
        {"receiptId": room.id, "receiptRevision": room.revision},
    )


def receipt_command(context: Any, payload: dict[str, Any]) -> None:
    """One receipt-room command (claim, review, dispute, host assignment, …) on a group receipt."""
    receipt_id = require_uuid(payload.get("receiptId"), "receiptId")
    command_type = payload.get("type")
    if command_type not in RECEIPT_COMMANDS:
        raise DomainError("invalid_payload", "Unknown receipt command")
    inner = model.require_dict(payload.get("payload", {}), "payload")
    access = ReceiptAccess(context)
    room = access.load(receipt_id)
    actor = _actor(room, context)
    if _expected(payload) != room.revision:
        raise _conflict(room)
    updated, changed = apply_command(room, actor, str(command_type), inner, context.now, max_amount=MAX_ABS_MINOR_UNITS)
    context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": updated.revision})
    if not changed:
        return
    access.store(updated)
    context.outcome.touched_receipts.add(receipt_id)
    data: dict[str, Any] = {"receiptId": receipt_id, "change": command_type, "revision": updated.revision}
    if isinstance(inner.get("itemId"), str):
        data["itemId"] = inner["itemId"]
    context.event("receiptUpdated", data)


def cancel_receipt(context: Any, payload: dict[str, Any]) -> None:
    """The host stops a pending receipt before it's finalized. No expense; balances never change."""
    receipt_id = require_uuid(payload.get("receiptId"), "receiptId")
    access = ReceiptAccess(context)
    room = access.load(receipt_id)
    context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": room.revision})
    if room.state == "cancelled":
        return
    updated, _ = apply_command(room, _actor(room, context), "cancel", {}, context.now, max_amount=MAX_ABS_MINOR_UNITS)
    access.store(updated)
    context.outcome.touched_receipts.add(receipt_id)
    context.outcome.result["receiptRevision"] = updated.revision
    context.event("receiptCancelled", {"receiptId": receipt_id, "title": _title(updated)})


def finalize_receipt(context: Any, payload: dict[str, Any], make_expense: Any) -> None:
    """The host finalizes: exactly one itemized expense, with the receipt's ID, created once.

    ``make_expense(room)`` records the expense in the group (``commands._record_receipt_expense``).
    A retry, a second device, or a double tap finds the receipt finalized and changes nothing."""
    receipt_id = require_uuid(payload.get("receiptId"), "receiptId")
    access = ReceiptAccess(context)
    room = access.load(receipt_id)
    _actor(room, context)
    if room.state == "finalized":
        context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": room.revision, "expenseId": receipt_id})
        return
    if _expected(payload) != room.revision:
        raise _conflict(room)
    acknowledged = payload.get("acknowledgeUnreviewed", [])
    updated, _ = apply_command(
        room, _actor(room, context), "finalize", {"acknowledgeUnreviewed": acknowledged}, context.now, max_amount=MAX_ABS_MINOR_UNITS
    )
    make_expense(updated)
    access.store(updated)
    context.outcome.touched_receipts.add(receipt_id)
    context.outcome.result.update({"receiptId": receipt_id, "receiptRevision": updated.revision, "expenseId": receipt_id})
    host_resolved = updated.finalization.host_resolved if updated.finalization else []
    context.event(
        "receiptFinalized", {"receiptId": receipt_id, "expenseId": receipt_id, "title": _title(updated), "hostResolved": host_resolved}
    )
