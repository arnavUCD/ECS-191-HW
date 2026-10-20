"""One authorized command against one shared-group aggregate.

The service layer authenticates, authorizes membership, checks idempotency and revisions, and
loads the aggregate inside a transaction; this module runs the deterministic rules (ported from
``LedgerEngine``) and returns what changed. It never touches storage.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from ..domain.errors import DomainError
from ..domain.money import MAX_ABS_MINOR_UNITS
from ..domain.room import Room, require_int, require_text, require_uuid
from . import group as model
from . import receipts
from .rules import (
    DRAFT_STATES,
    RESERVING_STATES,
    TERMINAL_STATES,
    apply_attempt_action,
    group_ledger,
    recompute_split,
    settlement_plan,
    validate_expense,
)

#: Commands that are refused against a stale group revision (they change membership, ownership,
#: or group-wide settings). Everything else is validated against the current ledger instead:
#: adding an expense or advancing your own payment doesn't depend on what you last saw, and the
#: server re-checks every rule (obligations, pending payments, membership) before applying it.
REVISION_STRICT = frozenset(
    {"updateGroup", "setSimplification", "removeMember", "transferOwnership", "archiveGroup", "leaveGroup", "addSeat"}
)

#: Commands only the owner may run (milestone 7 §3.2).
OWNER_ONLY = frozenset({"updateGroup", "setSimplification", "addSeat", "removeMember", "transferOwnership", "archiveGroup"})


@dataclass
class Outcome:
    changed: bool = False
    events: list[dict[str, Any]] = field(default_factory=list)
    revisions: list[dict[str, Any]] = field(default_factory=list)
    touched_expenses: set[str] = field(default_factory=set)
    touched_attempts: set[str] = field(default_factory=set)
    touched_settlements: set[str] = field(default_factory=set)
    touched_receipts: set[str] = field(default_factory=set)
    #: Group receipts to write (receipt ID → stored record), in the same transaction as the group.
    receipts: dict[str, dict[str, Any]] = field(default_factory=dict)
    result: dict[str, Any] = field(default_factory=dict)


#: Looks up a seat's enabled payment destination: (owner member id, destination id) → provider or None.
DestinationLookup = Callable[[str, str], str | None]
#: Loads a finalized Receipt Room the caller hosts, as its stored record (adoption).
RoomLoader = Callable[[str], dict[str, Any] | None]
#: Loads one of this group's receipts (pending allocations), as its stored record.
ReceiptLoader = Callable[[str], dict[str, Any] | None]


class Context:
    def __init__(
        self,
        group: dict[str, Any],
        actor: dict[str, Any],
        now: str,
        *,
        destination_provider: DestinationLookup,
        load_room: RoomLoader,
        actor_uid: str,
        load_receipt: ReceiptLoader | None = None,
    ) -> None:
        self.group = group
        self.actor = actor
        self.now = now
        self.destination_provider = destination_provider
        self.load_room = load_room
        self.actor_uid = actor_uid
        self.load_receipt: ReceiptLoader = load_receipt or (lambda _: None)
        self.outcome = Outcome()

    @property
    def actor_id(self) -> str:
        return str(self.actor["id"])

    def event(self, kind: str, data: dict[str, Any]) -> None:
        self.group["eventSequence"] += 1
        self.outcome.events.append(
            {
                "id": str(uuid.uuid4()),
                "sequence": self.group["eventSequence"],
                "actorMemberId": self.actor_id,
                "at": self.now,
                "kind": kind,
                "data": data,
            }
        )
        self.outcome.changed = True


def run(context: Context, command_type: str, payload: dict[str, Any]) -> Outcome:
    if context.group.get("archivedAt"):
        raise DomainError("group_archived", "This group was archived")
    if command_type in OWNER_ONLY and context.group["ownerMemberId"] != context.actor_id:
        raise DomainError("owner_only", "Only the group's owner can do that")
    handler = _HANDLERS.get(command_type)
    if handler is None:
        raise DomainError("invalid_payload", "Unknown command type")
    handler(context, payload)
    return context.outcome


# MARK: - Group settings


def _update_group(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    fields = model.parse_group_fields(payload)
    changed = [
        name
        for name, key in (("name", "name"), ("details", "details"), ("symbol", "symbol"), ("currency", "currency"))
        if fields[key] != group.get(key)
    ]
    if "currency" in changed and model.has_financial_records(group):
        raise DomainError("currency_locked", "The currency can't change after money has been recorded")
    if not changed:
        return
    group.update(fields)
    context.event("groupEdited", {"fields": changed})


def _set_simplification(context: Context, payload: dict[str, Any]) -> None:
    enabled = payload.get("enabled")
    if not isinstance(enabled, bool):
        raise DomainError("invalid_payload", "enabled must be true or false")
    if context.group["simplifiesDebts"] == enabled:
        return
    context.group["simplifiesDebts"] = enabled
    context.event("simplificationChanged", {"enabled": enabled})


# MARK: - Membership


def _add_seat(context: Context, payload: dict[str, Any]) -> None:
    """A named person without an account; they join by accepting a seat invitation."""
    group = context.group
    if len(group["members"]) >= model.MAX_SEATS:
        raise DomainError("group_full", "This group has reached its member limit")
    member_id = require_uuid(payload.get("memberId"), "memberId")
    existing = model.find_member(group, member_id)
    if existing is not None:
        if existing["status"] == "removed" and existing.get("uid") is None:
            existing["status"] = "pending"
            existing["removedAt"] = None
            context.event("memberAdded", {"memberId": member_id})
            context.outcome.result["memberId"] = member_id
            return
        if existing["displayName"] == payload.get("displayName"):
            context.outcome.result["memberId"] = member_id  # idempotent repeat
            return
        raise DomainError("entity_exists", "That person is already in this group")
    group["members"].append(model.new_seat(member_id, payload.get("displayName"), context.now, uid=None, handle=payload.get("handle")))
    context.event("memberAdded", {"memberId": member_id})
    context.outcome.result["memberId"] = member_id


def _member_obligations(group: dict[str, Any], member_id: str) -> tuple[int, bool]:
    ledger = group_ledger(model.member_ids(group), group["expenses"], group["settlements"])
    open_attempt = any(
        attempt["state"] not in TERMINAL_STATES and member_id in (attempt["payerId"], attempt["recipientId"])
        for attempt in group["attempts"]
    )
    return ledger.net(member_id), open_attempt


def _check_removable(group: dict[str, Any], member_id: str, *, rooms_hosted: bool = False) -> None:
    net, open_attempt = _member_obligations(group, member_id)
    if net != 0:
        raise DomainError("member_has_balance", "Settle this person's balance first", {"memberId": member_id, "balance": net})
    if open_attempt:
        raise DomainError("member_has_open_payment", "This person has a payment in progress", {"memberId": member_id})
    if rooms_hosted:
        raise DomainError("member_has_open_room", "This person is hosting a receipt room in this group")
    if receipts.has_open_receipt(group, member_id):
        # Their share of a receipt still being split would otherwise be left without them.
        raise DomainError(
            "member_has_open_receipt",
            "This person is on a receipt that's still being split. Finish or cancel it first",
            {"memberId": member_id},
        )


def leave_blocker(group: dict[str, Any], member_id: str) -> DomainError | None:
    """Why this member couldn't leave right now — the rule ``leaveGroup`` applies — or ``None``."""
    try:
        _check_removable(group, member_id)
    except DomainError as error:
        return error
    return None


def _remove_member(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    member_id = require_uuid(payload.get("memberId"), "memberId")
    if member_id == context.actor_id:
        raise DomainError("cannot_remove_yourself", "Transfer ownership or archive the group instead")
    member = model.find_member(group, member_id)
    if member is None or member["status"] == "removed":
        raise DomainError("not_a_member", "That person isn't in this group")
    _check_removable(group, member_id)
    member["status"] = "removed"
    member["removedAt"] = context.now
    context.outcome.result["removedUid"] = member.get("uid")
    context.event("memberRemoved", {"memberId": member_id})


def _leave_group(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    if group["ownerMemberId"] == context.actor_id:
        raise DomainError("owner_must_transfer", "Transfer ownership or archive the group before leaving")
    _check_removable(group, context.actor_id)
    context.actor["status"] = "removed"
    context.actor["removedAt"] = context.now
    context.outcome.result["removedUid"] = context.actor.get("uid")
    context.event("memberLeft", {"memberId": context.actor_id})


def _transfer_ownership(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    member_id = require_uuid(payload.get("memberId"), "memberId")
    member = model.find_member(group, member_id)
    if member is None or member["status"] != "active":
        raise DomainError("not_a_member", "Ownership can go only to someone who has joined")
    if member_id == context.actor_id:
        return
    group["ownerMemberId"] = member_id
    context.event("ownershipTransferred", {"fromMemberId": context.actor_id, "toMemberId": member_id})


def _archive_group(context: Context, payload: dict[str, Any]) -> None:
    """Closing the group safely: only once everyone is square and no payment is in progress, so no
    debt is left where it can no longer be settled. History stays readable."""
    group = context.group
    ledger = group_ledger(model.member_ids(group), group["expenses"], group["settlements"])
    if any(ledger.net(member_id) != 0 for member_id in model.member_ids(group)):
        raise DomainError("group_has_balances", "Settle everyone's balance before closing the group")
    if any(attempt["state"] not in TERMINAL_STATES for attempt in group["attempts"]):
        raise DomainError("group_has_open_payments", "Finish or cancel payments in progress before closing the group")
    if receipts.open_receipts(group):
        raise DomainError("group_has_open_receipts", "Finish or cancel receipts that are still being split before closing the group")
    context.group["archivedAt"] = context.now
    context.event("groupArchived", {})


# MARK: - Expenses


def _pending_conflicts(group: dict[str, Any], old: dict[str, Any] | None, new: dict[str, Any] | None) -> None:
    """``LedgerEngine.checkPendingConflicts``: refuse a change that would alter the balance of
    anyone with a reported or disputed payment until that payment is resolved."""
    reserving = [attempt for attempt in group["attempts"] if attempt["state"] in RESERVING_STATES]
    if not reserving:
        return
    excluded = {expense["id"] for expense in (old, new) if expense is not None}
    others = [expense for expense in group["expenses"] if expense["id"] not in excluded and not expense.get("deletedAt")]
    members = model.member_ids(group)
    before = group_ledger(members, others + ([old] if old and not old.get("deletedAt") else []), group["settlements"])
    after = group_ledger(members, others + ([new] if new and not new.get("deletedAt") else []), group["settlements"])
    conflicts = [
        attempt["id"]
        for attempt in reserving
        if any(before.net(member) != after.net(member) for member in (attempt["payerId"], attempt["recipientId"]))
    ]
    if conflicts:
        raise DomainError("pending_payment_conflict", "A payment waiting for confirmation depends on this", {"attemptIds": conflicts})


def _nonzero(shares: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """The app leaves zero shares out of an expense (e.g. 2¢ split three ways), so compare without them."""
    return [(member, amount) for member, amount in shares if amount != 0]


def _nonzero_shares(shares: list[dict[str, Any]]) -> list[tuple[str, int]]:
    return _nonzero([(share["memberId"], share["amount"]) for share in shares])


def _validated_expense(context: Context, payload: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    group = context.group
    expense = model.parse_expense(payload.get("expense"), currency=group["currency"])
    allowed = set(model.participating_ids(group))
    if previous is not None:
        allowed |= {share["memberId"] for share in previous["payments"] + previous["allocations"]}
    validate_expense(expense, group_member_ids=model.member_ids(group), participating_ids=allowed)
    split = model.parse_split(payload.get("split"))
    if split is not None:
        if split["method"] != expense["splitMethod"]:
            raise DomainError("invalid_split", "The split doesn't match its method")
        if _nonzero(recompute_split(expense["total"], split)) != _nonzero_shares(expense["allocations"]):
            raise DomainError("invalid_split", "The split doesn't match the server's calculation")
    elif expense["splitMethod"] == "equal":
        # An equal split is fully determined by the people in it, in order: recompute it.
        participants = [share["memberId"] for share in expense["allocations"]]
        if _nonzero(recompute_split(expense["total"], {"method": "equal", "participants": participants})) != _nonzero_shares(
            expense["allocations"]
        ):
            raise DomainError("invalid_split", "The split doesn't match the server's calculation")
    elif expense["splitMethod"] in ("shares", "percentage") and previous is None:
        # A new shares or percentage split must say how it was divided so it can be recomputed.
        # (An edit may reopen a saved split as its exact amounts, which only has to reconcile.)
        raise DomainError("invalid_split", "Describe how the split was divided")
    if expense["splitMethod"] == "itemized":
        receipt = payload.get("receipt")
        if receipt is None and previous is not None:
            expense["receipt"] = previous.get("receipt")
        elif receipt is None:
            raise DomainError("invalid_receipt", "An itemized expense needs its receipt")
        else:
            expense["receipt"] = model.parse_receipt_snapshot(receipt, expense, set(model.member_ids(group)))
    return expense


def _add_expense(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    expense = _validated_expense(context, payload, None)
    existing = next((stored for stored in group["expenses"] if stored["id"] == expense["id"]), None)
    if existing is not None:
        raise DomainError("entity_exists", "That expense already exists", {"expenseId": expense["id"]})
    if len(group["expenses"]) >= model.MAX_EXPENSES:
        raise DomainError("group_full", "This group has reached its expense limit")
    _pending_conflicts(group, None, expense)
    stored = {
        **expense,
        "createdBy": context.actor_id,
        "createdAt": context.now,
        "revision": 1,
        "updatedAt": None,
        "updatedBy": None,
        "deletedAt": None,
        "deletedBy": None,
        "roomId": expense.get("roomId"),
    }
    stored.setdefault("receipt", None)
    group["expenses"].append(stored)
    context.outcome.touched_expenses.add(stored["id"])
    context.outcome.revisions.append(
        {"expenseId": stored["id"], **model.revision_record(stored), "at": context.now, "actorMemberId": context.actor_id}
    )
    context.outcome.result["expenseId"] = stored["id"]
    context.event("expenseCreated", {"expenseId": stored["id"], "title": stored["title"], "total": stored["total"]})


def _own_expense(context: Context, payload: dict[str, Any], *, owner_may: bool = False) -> dict[str, Any]:
    """The expense the caller may change: their own, or — for deleting and restoring only — any
    expense when the caller owns the group (resolving an exceptional case, recorded as such)."""
    expense_id = require_uuid(payload.get("expenseId"), "expenseId")
    expense: dict[str, Any] | None = next((stored for stored in context.group["expenses"] if stored["id"] == expense_id), None)
    if expense is None:
        raise DomainError("expense_not_found", "That expense isn't in this group")
    by_owner = owner_may and context.group["ownerMemberId"] == context.actor_id
    if expense["createdBy"] != context.actor_id and not by_owner:
        raise DomainError("forbidden", "Only the person who added this expense can change it")
    expected = payload.get("expectedExpenseRevision")
    if expected is not None and require_int(expected, "expectedExpenseRevision", low=1, high=1_000_000) != expense["revision"]:
        raise DomainError(
            "expense_conflict", "Someone changed this expense", {"expenseId": expense_id, "currentRevision": expense["revision"]}
        )
    return expense


def _update_expense(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    old = _own_expense(context, payload)
    if old.get("deletedAt"):
        raise DomainError("expense_deleted", "Restore this expense before editing it")
    expense = _validated_expense(context, payload, old)
    if expense["id"] != old["id"]:
        raise DomainError("invalid_payload", "expense.id must match expenseId")
    fields = model.changed_fields(old, expense)
    if not fields:
        return
    _pending_conflicts(group, old, expense)
    previous = model.revision_record(old)
    updated = {
        **old,
        **expense,
        "receipt": expense.get("receipt") if expense["splitMethod"] == "itemized" else None,
        "revision": old["revision"] + 1,
        "updatedAt": context.now,
        "updatedBy": context.actor_id,
    }
    group["expenses"] = [updated if stored["id"] == old["id"] else stored for stored in group["expenses"]]
    context.outcome.touched_expenses.add(updated["id"])
    context.outcome.revisions.append(
        {"expenseId": updated["id"], **model.revision_record(updated), "at": context.now, "actorMemberId": context.actor_id}
    )
    context.outcome.result["expenseId"] = updated["id"]
    context.event(
        "expenseEdited",
        {"expenseId": updated["id"], "title": updated["title"], "fields": fields, "previous": previous, "revision": updated["revision"]},
    )


def _delete_expense(context: Context, payload: dict[str, Any]) -> None:
    expense = _own_expense(context, payload, owner_may=True)
    if expense.get("deletedAt"):
        # Same rule as ``LedgerEngine``: a second, different delete is refused (a retry of the same
        # request is answered from its idempotency record instead).
        raise DomainError("expense_deleted", "This expense was already deleted")
    _pending_conflicts(context.group, expense, None)
    expense["deletedAt"] = context.now
    expense["deletedBy"] = context.actor_id
    context.outcome.touched_expenses.add(expense["id"])
    context.event(
        "expenseDeleted", {"expenseId": expense["id"], "snapshot": model.revision_record(expense), **_owner_note(context, expense)}
    )


def _owner_note(context: Context, expense: dict[str, Any]) -> dict[str, Any]:
    """History notes when the owner acted on someone else's expense."""
    return {"byOwner": True} if expense["createdBy"] != context.actor_id else {}


def _restore_expense(context: Context, payload: dict[str, Any]) -> None:
    expense = _own_expense(context, payload, owner_may=True)
    if not expense.get("deletedAt"):
        raise DomainError("expense_not_deleted", "This expense isn't deleted")
    restored = {**expense, "deletedAt": None, "deletedBy": None}
    allowed = set(model.participating_ids(context.group)) | {share["memberId"] for share in expense["payments"] + expense["allocations"]}
    validate_expense(restored, group_member_ids=model.member_ids(context.group), participating_ids=allowed)
    _pending_conflicts(context.group, None, restored)
    expense["deletedAt"] = None
    expense["deletedBy"] = None
    context.outcome.touched_expenses.add(expense["id"])
    context.event("expenseRestored", {"expenseId": expense["id"], "title": expense["title"], **_owner_note(context, expense)})


# MARK: - Receipt rooms


def _adopt_room(context: Context, payload: dict[str, Any]) -> None:
    """Records a finalized server-side Live Receipt Room as one itemized group expense — once.

    The allocation comes from the room's own finalization record (computed by the server's
    allocation engine), never from the client. Guests who joined the room without a group seat
    must be matched to group members by the host first.
    """
    group = context.group
    room_id = require_uuid(payload.get("roomId"), "roomId")
    if room_id in group["adoptedRooms"]:
        context.outcome.result["expenseId"] = room_id
        return
    record = context.load_room(room_id)
    if record is None or record.get("hostUid") != context.actor_uid:
        raise DomainError("room_not_found", "This receipt isn't available")
    if record.get("state") != "finalized" or not record.get("finalization"):
        raise DomainError("room_not_adoptable", "Finalize the receipt room first")
    if record["receipt"].get("currency") != group["currency"]:
        raise DomainError("currency_mismatch", "This receipt uses a different currency than the group")
    finalization: dict[str, Any] = record["finalization"]
    guest_map_raw = model.require_dict(payload.get("guestMembers", {}), "guestMembers")
    guest_map = {require_uuid(key, "guestMembers"): require_uuid(value, "guestMembers") for key, value in guest_map_raw.items()}
    members = set(model.member_ids(group))

    def to_member(participant_id: str) -> str:
        member = guest_map.get(participant_id, participant_id)
        if member not in members:
            raise DomainError(
                "guests_not_matched", "Match everyone at the table to a group member first", {"participantId": participant_id}
            )
        return member

    title = _record_itemized_expense(context, room_id, record["receipt"], finalization, str(record["payerId"]), to_member)
    group["adoptedRooms"].append(room_id)
    context.event("receiptRoomAdopted", {"roomId": room_id, "expenseId": room_id, "title": title})


def _record_itemized_expense(
    context: Context,
    expense_id: str,
    receipt: dict[str, Any],
    finalization: dict[str, Any],
    payer_participant: str,
    to_member: Callable[[str], str],
) -> str:
    """Adds the one itemized expense a finalized receipt becomes (a shared room's or a group
    receipt's). The allocation is the server's own finalization record — per-person totals, item
    and charge shares — never anything a client sent. Returns the expense's title."""
    group = context.group
    members = set(model.member_ids(group))
    participating = set(model.participating_ids(group))
    totals: dict[str, int] = {}
    participants = []
    for entry in finalization["participants"]:
        member = to_member(entry["participantId"])
        totals[member] = totals.get(member, 0) + int(entry["total"])
        participants.append(
            {
                "memberId": member,
                **{key: int(entry.get(key, 0)) for key in ("items", "tax", "tip", "fees", "discounts", "adjustments")},
                "total": int(entry["total"]),
            }
        )
    payer = to_member(payer_participant)
    total = int(finalization["total"])
    expense = {
        "id": expense_id,
        "title": receipt.get("merchant") or "Receipt",
        "merchant": receipt.get("merchant") or None,
        "date": f"{receipt['date']}T12:00:00Z" if receipt.get("date") and len(receipt["date"]) == 10 else context.now,
        "total": total,
        "category": "food",
        "splitMethod": "itemized",
        "payments": [{"memberId": payer, "amount": total}],
        "allocations": [{"memberId": member, "amount": units} for member, units in totals.items() if units != 0],
        "note": None,
    }
    validate_expense(expense, group_member_ids=members, participating_ids=participating)
    snapshot: dict[str, Any] = {
        "merchant": receipt.get("merchant") or "",
        "date": expense["date"],
        "total": total,
        "items": [
            {**item, "shares": [{"memberId": to_member(s["participantId"]), "amount": s["amount"]} for s in item["shares"]]}
            for item in finalization["items"]
        ],
        "charges": [
            {**charge, "shares": [{"memberId": to_member(s["participantId"]), "amount": s["amount"]} for s in charge["shares"]]}
            for charge in finalization["charges"]
        ],
        "participants": participants,
        "rounding": [],
    }
    if finalization.get("hostResolved"):
        # Shares the host finalized without that person's review: part of the record, shown with it.
        snapshot["hostResolved"] = [to_member(pid) for pid in finalization["hostResolved"]]
    expense["receipt"] = snapshot
    expense["roomId"] = expense_id
    if any(stored["id"] == expense_id for stored in group["expenses"]):
        raise DomainError("entity_exists", "That expense already exists", {"expenseId": expense_id})
    _pending_conflicts(group, None, expense)
    stored = {
        **expense,
        "createdBy": context.actor_id,
        "createdAt": context.now,
        "revision": 1,
        "updatedAt": None,
        "updatedBy": None,
        "deletedAt": None,
        "deletedBy": None,
    }
    group["expenses"].append(stored)
    context.outcome.touched_expenses.add(expense_id)
    context.outcome.revisions.append(
        {"expenseId": expense_id, **model.revision_record(stored), "at": context.now, "actorMemberId": context.actor_id}
    )
    context.outcome.result["expenseId"] = expense_id
    context.event("expenseCreated", {"expenseId": expense_id, "title": stored["title"], "total": total})
    return str(stored["title"])


# MARK: - Group receipts (pending receipt allocations)


def _post_receipt(context: Context, payload: dict[str, Any]) -> None:
    receipts.post_receipt(context, payload)


def _receipt_command(context: Context, payload: dict[str, Any]) -> None:
    receipts.receipt_command(context, payload)


def _cancel_receipt(context: Context, payload: dict[str, Any]) -> None:
    receipts.cancel_receipt(context, payload)


def _finalize_receipt(context: Context, payload: dict[str, Any]) -> None:
    def make_expense(room: Room) -> None:
        if room.finalization is None or room.payer_id is None:  # pragma: no cover - the engine guarantees both
            raise DomainError("not_ready_to_finalize", "Some items or charges still need attention", {"issues": []})
        if room.receipt.currency != context.group["currency"]:
            raise DomainError("currency_mismatch", "This receipt uses a different currency than the group")
        _record_itemized_expense(context, room.id, room.receipt.to_wire(), room.finalization.to_wire(), room.payer_id, lambda pid: pid)

    receipts.finalize_receipt(context, payload, make_expense)


# MARK: - Payments


def _available_obligation(group: dict[str, Any], payer: str, recipient: str, excluding: str | None = None) -> int | None:
    attempts = [attempt for attempt in group["attempts"] if attempt["id"] != excluding]
    plan = settlement_plan(model.member_ids(group), group["expenses"], group["settlements"], attempts, bool(group["simplifiesDebts"]))
    payment = plan.payment(payer, recipient)
    return None if payment is None else payment.amount


def _attempt_info(attempt: dict[str, Any]) -> dict[str, Any]:
    return {
        "attemptId": attempt["id"],
        "payerId": attempt["payerId"],
        "recipientId": attempt["recipientId"],
        "amount": attempt["amount"],
        "provider": attempt["provider"],
    }


def _start_payment(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    attempt_id = require_uuid(payload.get("attemptId"), "attemptId")
    existing = next((attempt for attempt in group["attempts"] if attempt["id"] == attempt_id), None)
    if existing is not None:
        raise DomainError("entity_exists", "That payment already exists", {"attemptId": attempt_id})
    recipient_id = require_uuid(payload.get("recipientId"), "recipientId")
    amount = require_int(payload.get("amount"), "amount", low=1, high=MAX_ABS_MINOR_UNITS)
    provider = payload.get("provider")
    if provider not in model.PROVIDERS:
        raise DomainError("invalid_payload", "Unknown payment method")
    if recipient_id == context.actor_id:
        raise DomainError("cannot_pay_self", "You can't pay yourself")
    recipient = model.find_member(group, recipient_id)
    if recipient is None or recipient["status"] == "removed":
        raise DomainError("not_a_member", "That person isn't in this group")
    if recipient["status"] != "active":
        raise DomainError("recipient_not_joined", "They need to join the group before they can confirm a payment")
    owed = _available_obligation(group, context.actor_id, recipient_id)
    if owed is None:
        raise DomainError("no_obligation", "You don't owe them anything right now")
    if amount > owed:
        raise DomainError("exceeds_obligation", "That's more than you owe them now", {"owed": owed})
    destination_id = payload.get("destinationId")
    if destination_id is not None:
        destination_id = require_uuid(destination_id, "destinationId")
        if context.destination_provider(recipient_id, destination_id) != provider:
            raise DomainError("destination_unavailable", "That payment method isn't available anymore")
    if len(group["attempts"]) >= model.MAX_ATTEMPTS:
        raise DomainError("group_full", "This group has reached its payment limit")
    # Opening a second handoff for the same obligation replaces the older draft.
    for draft in group["attempts"]:
        if draft["payerId"] == context.actor_id and draft["recipientId"] == recipient_id and draft["state"] in DRAFT_STATES:
            apply_attempt_action(draft, "cancel", context.actor_id, context.now, "superseded")
            context.outcome.touched_attempts.add(draft["id"])
            context.event("paymentCancelled", {**_attempt_info(draft), "reason": "superseded"})
    memo = require_text(payload.get("memo", ""), "memo", max_length=model.MAX_TITLE, allow_empty=True)
    attempt = {
        "id": attempt_id,
        "payerId": context.actor_id,
        "recipientId": recipient_id,
        "destinationId": destination_id,
        "provider": provider,
        "amount": amount,
        "memo": memo,
        "state": "methodSelected",
        "history": [{"state": "methodSelected", "actorId": context.actor_id, "at": context.now, "note": None}],
        "externalReference": None,
        "settlementId": None,
    }
    group["attempts"].append(attempt)
    context.outcome.touched_attempts.add(attempt_id)
    context.outcome.result["attemptId"] = attempt_id
    context.event("paymentStarted", _attempt_info(attempt))


def _record_settlement(context: Context, payload: dict[str, Any]) -> None:
    """ "Mark as settled": the person who is owed records that someone paid them outside Square Up,
    or that they don't need it back. Only the person owed may do it, never for more than they're
    owed right now, so it can only lower someone else's balance. It's recorded as a settlement the
    recipient confirmed (``settlementRecorded``), exactly like one they confirmed after a report."""
    group = context.group
    settlement_id = require_uuid(payload.get("settlementId"), "settlementId")
    if any(stored["id"] == settlement_id for stored in group["settlements"]):
        raise DomainError("entity_exists", "That payment is already recorded", {"settlementId": settlement_id})
    payer_id = require_uuid(payload.get("payerId"), "payerId")
    amount = require_int(payload.get("amount"), "amount", low=1, high=MAX_ABS_MINOR_UNITS)
    provider = payload.get("provider", "other")
    if provider not in model.PROVIDERS:
        raise DomainError("invalid_payload", "Unknown payment method")
    if payer_id == context.actor_id:
        raise DomainError("cannot_pay_self", "You can't pay yourself")
    payer = model.find_member(group, payer_id)
    if payer is None or payer["status"] == "removed":
        raise DomainError("not_a_member", "That person isn't in this group")
    owed = _available_obligation(group, payer_id, context.actor_id)
    if owed is None:
        raise DomainError("no_obligation", "They don't owe you anything right now")
    if amount > owed:
        raise DomainError("exceeds_obligation", "That's more than they owe you now", {"owed": owed})
    if len(group["settlements"]) >= model.MAX_ATTEMPTS:
        raise DomainError("group_full", "This group has reached its payment limit")
    group["settlements"].append(
        {
            "id": settlement_id,
            "fromId": payer_id,
            "toId": context.actor_id,
            "amount": amount,
            "date": context.now,
            "recordedBy": context.actor_id,
            "provider": provider,
            "attemptId": None,
            "confirmedAt": context.now,
            "confirmedBy": context.actor_id,
        }
    )
    context.outcome.touched_settlements.add(settlement_id)
    context.outcome.result["settlementId"] = settlement_id
    context.event(
        "settlementRecorded",
        {"settlementId": settlement_id, "fromId": payer_id, "toId": context.actor_id, "amount": amount, "byRecipient": True},
    )


_ACTION_EVENTS = {
    "reportSent": "paymentReported",
    "confirm": "paymentConfirmed",
    "reject": "paymentRejected",
    "dispute": "paymentDisputed",
    "cancel": "paymentCancelled",
}


def _advance_payment(context: Context, payload: dict[str, Any]) -> None:
    group = context.group
    attempt_id = require_uuid(payload.get("attemptId"), "attemptId")
    attempt = next((stored for stored in group["attempts"] if stored["id"] == attempt_id), None)
    if attempt is None or context.actor_id not in (attempt["payerId"], attempt["recipientId"]):
        raise DomainError("attempt_not_found", "That payment isn't available")
    action = payload.get("action")
    if action not in ("openHandoff", "reportSent", "confirm", "reject", "dispute", "cancel"):
        raise DomainError("invalid_payload", "Unknown payment action")
    note: str | None = None
    if action in ("reject", "dispute"):
        note = model.optional_text(payload.get("reason"), "reason", model.MAX_REASON)
    if action == "cancel":
        note = "payerCancelled"
    before = dict(attempt, history=list(attempt["history"]))
    if not apply_attempt_action(attempt, action, context.actor_id, context.now, note):
        context.outcome.result["attemptId"] = attempt_id
        context.outcome.result["settlementId"] = attempt.get("settlementId")
        return
    if action == "reportSent":
        # The plan may have changed since the draft began; never reserve more than is still owed.
        owed = _available_obligation(group, before["payerId"], before["recipientId"], excluding=attempt_id)
        if owed is None:
            raise DomainError("no_obligation", "You don't owe them anything right now")
        if before["amount"] > owed:
            raise DomainError("exceeds_obligation", "That's more than you owe them now", {"owed": owed})
        reference = model.optional_text(payload.get("externalReference"), "externalReference", model.MAX_REFERENCE)
        attempt["externalReference"] = reference
    context.outcome.touched_attempts.add(attempt_id)
    context.outcome.result["attemptId"] = attempt_id
    info = _attempt_info(attempt)
    if action == "openHandoff":
        context.event("paymentHandoffOpened", info)
        return
    if action == "confirm":
        # Deterministic identifier: one attempt can only ever produce this one settlement.
        settlement_id = attempt_id
        if not any(s["id"] == settlement_id or s.get("attemptId") == attempt_id for s in group["settlements"]):
            group["settlements"].append(
                {
                    "id": settlement_id,
                    "fromId": attempt["payerId"],
                    "toId": attempt["recipientId"],
                    "amount": attempt["amount"],
                    "date": context.now,
                    "recordedBy": attempt["payerId"],
                    "provider": attempt["provider"],
                    "attemptId": attempt_id,
                    "confirmedAt": context.now,
                    "confirmedBy": context.actor_id,
                }
            )
            context.outcome.touched_settlements.add(settlement_id)
        attempt["settlementId"] = settlement_id
        context.outcome.result["settlementId"] = settlement_id
        context.event("paymentConfirmed", {**info, "settlementId": settlement_id})
        return
    data = dict(info)
    if action == "cancel":
        data["reason"] = "payerCancelled"
    context.event(_ACTION_EVENTS[action], data)


_HANDLERS: dict[str, Callable[[Context, dict[str, Any]], None]] = {
    "updateGroup": _update_group,
    "setSimplification": _set_simplification,
    "addSeat": _add_seat,
    "removeMember": _remove_member,
    "leaveGroup": _leave_group,
    "transferOwnership": _transfer_ownership,
    "archiveGroup": _archive_group,
    "addExpense": _add_expense,
    "updateExpense": _update_expense,
    "deleteExpense": _delete_expense,
    "restoreExpense": _restore_expense,
    "adoptRoom": _adopt_room,
    "postReceipt": _post_receipt,
    "receiptCommand": _receipt_command,
    "finalizeReceipt": _finalize_receipt,
    "cancelReceipt": _cancel_receipt,
    "startPayment": _start_payment,
    "advancePayment": _advance_payment,
    "recordSettlement": _record_settlement,
}
