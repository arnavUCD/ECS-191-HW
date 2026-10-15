"""The authoritative Receipt Room command engine — a port of the Swift `LedgerEngine+Receipts`.

Pure: :func:`apply_command` validates a command against a copy of the room and returns the
changed room, or raises :class:`DomainError` without side effects. Permissions (the milestone 4
authorization matrix) and allowed states are declared per command type, exactly as in Swift.

Revision semantics: every command that changes the room increments ``revision`` by exactly one.
A command that changes nothing (a repeat) leaves the revision unchanged.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Any

from .allocation import ChargeResult, ItemResult, allocate, allocate_charge, preview_split
from .errors import DomainError
from .readiness import readiness_issues, unreviewed_participants
from .room import (
    MAX_PARTICIPANTS,
    MAX_SHARE_WEIGHT,
    MAX_UNITS,
    Charge,
    ChargeAllocation,
    Claim,
    ClaimMode,
    Dispute,
    Finalization,
    HistoryEntry,
    Room,
    new_id,
    optional_note,
    require_int,
    require_uuid,
)
from .room_payments import PAYMENT_COMMANDS, apply_payment_command, obligations_after_finalization
from .wire import receipt_from_wire

#: Host-only commands (everything else is "participant": any room participant, and the host).
HOST_ONLY = {
    "resolveDispute",
    "setChargeAllocation",
    "reviseReceipt",
    "setPayerAcceptsFullReceipt",
    "transition",
    "cancel",
    "removeParticipant",
    "finalize",
}
PARTICIPANT_COMMANDS = {"claim", "unclaim", "claimUnits", "setItemSplit", "dispute", "markReviewed"}
COMMAND_TYPES = HOST_ONLY | PARTICIPANT_COMMANDS | PAYMENT_COMMANDS
ACTIVE = ("open", "resolving", "readyToFinalize")

#: Allowed states per command; ``None`` = claiming rules (open, or resolving for the host).
ALLOWED_STATES: dict[str, tuple[str, ...] | None] = {
    "claim": None,
    "unclaim": None,
    "claimUnits": None,
    "setItemSplit": None,
    "dispute": ACTIVE,
    "resolveDispute": ACTIVE,
    "setChargeAllocation": ACTIVE,
    "reviseReceipt": ACTIVE,
    "markReviewed": ACTIVE,
    "setPayerAcceptsFullReceipt": ACTIVE,
    "removeParticipant": ACTIVE,
    "transition": ("open", "resolving", "readyToFinalize"),
    "cancel": ("open", "resolving", "readyToFinalize"),
    "finalize": ("readyToFinalize",),
}


@dataclass
class Actor:
    participant_id: str
    is_host: bool


def apply_command(room: Room, actor: Actor, command_type: str, payload: dict[str, Any], now: str, max_amount: int) -> tuple[Room, bool]:
    """Apply one command. Returns ``(room, changed)``. Raises :class:`DomainError` on violation."""
    if command_type not in COMMAND_TYPES:
        raise DomainError("invalid_payload", "Unknown command type")
    if not isinstance(payload, dict):
        raise DomainError("invalid_payload", "payload must be an object")
    if room.closed_at is not None:
        raise DomainError("room_closed", "This room has ended")
    working = copy.deepcopy(room)
    if command_type in PAYMENT_COMMANDS:
        # Paying the payer happens after finalization, in temporary rooms only.
        participant = room.participant(actor.participant_id)
        if participant is None or not participant.is_active:
            raise DomainError("not_a_participant", "Only people in this room can do that")
        changed = apply_payment_command(working, actor.participant_id, command_type, payload, now)
        return _recorded(room, working, actor, command_type, payload, now) if changed else (room, False)
    if room.state == "finalized":
        raise DomainError("room_finalized", "This receipt was already saved as an expense")
    if room.state == "cancelled":
        raise DomainError("room_cancelled", "The host closed this room")
    participant = room.participant(actor.participant_id)
    if participant is None or not participant.is_active:
        raise DomainError("not_a_participant", "Only people in this room can do that")
    if command_type in HOST_ONLY and not actor.is_host:
        raise DomainError("host_only", "Only the host can do that")
    allowed = ALLOWED_STATES[command_type]
    if allowed is None:
        if not (room.state == "open" or (room.state == "resolving" and actor.is_host)):
            raise DomainError("not_allowed_in_state", "Claiming is closed right now", {"state": room.state})
    elif room.state not in allowed:
        raise DomainError("not_allowed_in_state", "That isn't possible right now", {"state": room.state})

    handler = _HANDLERS[command_type]
    changed = handler(working, actor, payload, now, max_amount)
    if not changed:
        return room, False
    return _recorded(room, working, actor, command_type, payload, now)


def _recorded(room: Room, working: Room, actor: Actor, command_type: str, payload: dict[str, Any], now: str) -> tuple[Room, bool]:
    """Advances the revision by one and appends the history entry for an applied command."""
    working.revision = room.revision + 1
    working.updated_at = now
    working.history.append(
        HistoryEntry(
            sequence=(room.history[-1].sequence if room.history else 0) + 1,
            revision=working.revision,
            actor_id=actor.participant_id,
            at=now,
            type=command_type,
            detail=_history_detail(command_type, payload),
        )
    )
    return working, True


def _history_detail(command_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Identifiers only — never free text, so history can be shown and logged safely."""
    keys = ("itemId", "chargeId", "disputeId", "request", "move", "status", "participantId")
    return {key: payload[key] for key in keys if isinstance(payload.get(key), str)}


# MARK: - Claims


def _claimable(room: Room, item_id: str) -> None:
    item = room.receipt.item(item_id)
    if item is None:
        raise DomainError("item_not_found", "That item is no longer on the receipt")
    if item.is_note:
        raise DomainError("item_not_claimable", "Zero-value lines are notes and can't be claimed")


def _claim(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    item_id = require_uuid(payload.get("itemId"), "itemId")
    request = payload.get("request")
    if request not in ("mine", "share"):
        raise DomainError("invalid_payload", "request must be mine or share")
    _claimable(room, item_id)
    if actor.participant_id not in room.participant_ids:
        raise DomainError("not_a_participant", "Only people in this room can do that")
    if room.claim(item_id, actor.participant_id) is not None:
        return False  # already claimed: idempotent
    others = [c for c in room.claims_for(item_id) if c.participant_id != actor.participant_id]
    if request == "mine":
        if others:
            raise DomainError(
                "item_already_claimed",
                "Someone already claimed this. Share it or dispute it instead",
                {"participantId": others[0].participant_id},
            )
        room.claims.append(Claim(item_id, actor.participant_id, ClaimMode("full")))
        return True
    if any(c.mode.kind == "exact" for c in others):
        raise DomainError("item_has_custom_split", "This item has exact amounts. Use Custom split to change it")
    if any(c.mode.kind == "units" for c in others):
        raise DomainError("item_has_custom_split", "This item is split by quantity. Choose how many you had")
    uses_weights = any(c.mode.kind == "shares" for c in others)
    for claim in room.claims:
        if claim.item_id == item_id and claim.mode.kind == "full":
            claim.mode = ClaimMode("equalShare")
    if uses_weights:
        mode = ClaimMode("shares", shares=1)
    elif others:
        mode = ClaimMode("equalShare")
    else:
        mode = ClaimMode("full")
    room.claims.append(Claim(item_id, actor.participant_id, mode))
    return True


def _unclaim(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    item_id = require_uuid(payload.get("itemId"), "itemId")
    if room.claim(item_id, actor.participant_id) is None:
        raise DomainError("no_claim_to_remove", "You haven't claimed this item")
    room.claims = [c for c in room.claims if not (c.item_id == item_id and c.participant_id == actor.participant_id)]
    return True


def _claim_units(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    """ "I had 2 of the 3": sets the caller's own claim to a number of the line's printed quantity.

    Other people's unit claims are never changed; asking for more than is left is refused with
    what's still available. ``units: 0`` removes the caller's claim."""
    item_id = require_uuid(payload.get("itemId"), "itemId")
    units = require_int(payload.get("units"), "units", low=0, high=MAX_UNITS)
    _claimable(room, item_id)
    item = room.receipt.item(item_id)
    if item is None or item.quantity is None or item.quantity < 1:
        raise DomainError("item_quantity_unknown", "This item doesn't list a quantity. Claim it or share it instead")
    if actor.participant_id not in room.participant_ids:
        raise DomainError("not_a_participant", "Only people in this room can do that")
    mine = room.claim(item_id, actor.participant_id)
    others = [c for c in room.claims_for(item_id) if c.participant_id != actor.participant_id]
    if units == 0:
        if mine is None:
            return False
        room.claims = [c for c in room.claims if not (c.item_id == item_id and c.participant_id == actor.participant_id)]
        return True
    holder = next((c for c in others if c.mode.kind == "full"), None)
    if holder is not None:
        raise DomainError(
            "item_already_claimed",
            "Someone already claimed all of this. Dispute it if that's wrong",
            {"participantId": holder.participant_id},
        )
    if any(c.mode.kind != "units" for c in others):
        raise DomainError("item_has_custom_split", "This item is already divided another way. Ask the host to change it")
    available = item.quantity - sum(c.mode.units or 0 for c in others)
    if units > available:
        raise DomainError("units_unavailable", "That's more than is left on this line", {"available": max(available, 0)})
    if mine is not None and mine.mode.kind == "units" and mine.mode.units == units:
        return False
    room.claims = [c for c in room.claims if not (c.item_id == item_id and c.participant_id == actor.participant_id)]
    room.claims.append(Claim(item_id, actor.participant_id, ClaimMode("units", units=units)))
    return True


def parse_split(raw: object, max_amount: int) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("kind") not in ("equal", "shares", "exact", "units"):
        raise DomainError("invalid_payload", "split.kind is invalid")
    kind = raw["kind"]
    if kind == "units":
        entries = raw.get("units")
        if not isinstance(entries, list) or len(entries) > MAX_PARTICIPANTS:
            raise DomainError("invalid_payload", "split.units is invalid")
        counts = []
        for entry in entries:
            if not isinstance(entry, dict):
                raise DomainError("invalid_payload", "split.units is invalid")
            counts.append(
                (
                    require_uuid(entry.get("participantId"), "participantId"),
                    require_int(entry.get("units"), "units", low=0, high=MAX_UNITS),
                )
            )
        if len({pid for pid, _ in counts}) != len(counts):
            raise DomainError("invalid_payload", "split.units lists someone twice")
        return {"kind": "units", "units": counts}
    if kind == "equal":
        members = raw.get("members")
        if not isinstance(members, list) or len(members) > MAX_PARTICIPANTS:
            raise DomainError("invalid_payload", "split.members is invalid")
        return {"kind": "equal", "members": [require_uuid(m, "split.members") for m in members]}
    if kind == "shares":
        weights = raw.get("weights")
        if not isinstance(weights, list) or len(weights) > MAX_PARTICIPANTS:
            raise DomainError("invalid_payload", "split.weights is invalid")
        parsed = []
        for entry in weights:
            if not isinstance(entry, dict):
                raise DomainError("invalid_payload", "split.weights is invalid")
            parsed.append(
                (
                    require_uuid(entry.get("participantId"), "participantId"),
                    require_int(entry.get("weight"), "weight", low=0, high=MAX_SHARE_WEIGHT),
                )
            )
        return {"kind": "shares", "weights": parsed}
    amounts = raw.get("amounts")
    if not isinstance(amounts, list) or len(amounts) > MAX_PARTICIPANTS:
        raise DomainError("invalid_payload", "split.amounts is invalid")
    parsed_amounts = []
    for entry in amounts:
        if not isinstance(entry, dict):
            raise DomainError("invalid_payload", "split.amounts is invalid")
        parsed_amounts.append(
            (
                require_uuid(entry.get("participantId"), "participantId"),
                require_int(entry.get("amount"), "amount", low=-max_amount, high=max_amount),
            )
        )
    return {"kind": "exact", "amounts": parsed_amounts}


def _split_members(split: dict[str, Any]) -> list[str]:
    if split["kind"] == "equal":
        return list(split["members"])
    if split["kind"] == "shares":
        return [pid for pid, _ in split["weights"]]
    if split["kind"] == "units":
        return [pid for pid, count in split["units"] if count > 0]
    return [pid for pid, _ in split["amounts"]]


def _claims_for_split(split: dict[str, Any], item_id: str) -> list[Claim]:
    if split["kind"] == "equal":
        members = split["members"]
        return [Claim(item_id, pid, ClaimMode("full" if len(members) == 1 else "equalShare")) for pid in members]
    if split["kind"] == "shares":
        return [Claim(item_id, pid, ClaimMode("shares", shares=w)) for pid, w in split["weights"] if w > 0]
    if split["kind"] == "units":
        return [Claim(item_id, pid, ClaimMode("units", units=count)) for pid, count in split["units"] if count > 0]
    return [Claim(item_id, pid, ClaimMode("exact", amount=v)) for pid, v in split["amounts"] if v != 0]


def _set_split(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    item_id = require_uuid(payload.get("itemId"), "itemId")
    split = parse_split(payload.get("split"), max_amount)
    _claimable(room, item_id)
    item = room.receipt.item(item_id)
    if item is None:
        raise DomainError("item_not_found", "That item isn't on this receipt")
    previous = room.claims_for(item_id)
    members = _split_members(split)
    outsider = next((pid for pid in members if pid not in room.participant_ids), None)
    if outsider is not None:
        raise DomainError("participant_not_in_room", "That person isn't in this room", {"participantId": outsider})
    if not actor.is_host:
        allowed = {c.participant_id for c in previous} | {actor.participant_id}
        includes_self = actor.participant_id in members or any(c.participant_id == actor.participant_id for c in previous)
        if not all(pid in allowed for pid in members) or not includes_self:
            raise DomainError("cannot_include_others", "You can divide an item only among people who claimed it. Ask others to tap Share")
    clearing = not members
    if clearing:
        if not actor.is_host:
            raise DomainError("invalid_split", "Choose at least one person", {"issue": "noOne"})
        claims: list[Claim] = []
    else:
        issue, _, remaining = preview_split(item, split)
        if issue is not None:
            raise DomainError("invalid_split", "That split doesn't add up", {"issue": issue, "remaining": remaining})
        claims = _claims_for_split(split, item_id)
    if not actor.is_host:
        # Re-dividing never drops someone else's claim: only they (by unclaiming) or the host can.
        kept = {c.participant_id for c in claims}
        if any(c.participant_id not in kept for c in previous if c.participant_id != actor.participant_id):
            raise DomainError("cannot_remove_others", "You can't remove someone else's claim. Ask them, or the host")

    def key(entries: list[Claim]) -> list[str]:
        return sorted(f"{c.participant_id}|{c.mode.key()}" for c in entries)

    if key(claims) == key(previous):
        return False
    room.claims = [c for c in room.claims if c.item_id != item_id] + claims
    return True


# MARK: - Disputes, reviews, charges


def _dispute(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    target = payload.get("target")
    if not isinstance(target, dict) or target.get("kind") not in ("item", "charge"):
        raise DomainError("invalid_payload", "target is invalid")
    target_id = require_uuid(target.get("id"), "target.id")
    if target["kind"] == "item" and room.receipt.item(target_id) is None:
        raise DomainError("item_not_found", "That item is no longer on the receipt")
    if target["kind"] == "charge" and room.receipt.charge(target_id) is None:
        raise DomainError("charge_not_found", "That charge is no longer on the receipt")
    note = optional_note(payload.get("note"))
    if any(
        d.target_kind == target["kind"] and d.target_id == target_id and d.raised_by == actor.participant_id and d.is_open
        for d in room.disputes
    ):
        return False
    room.disputes.append(
        Dispute(
            id=_dispute_id(payload),
            target_kind=target["kind"],
            target_id=target_id,
            raised_by=actor.participant_id,
            note=note,
            created_at=now,
        )
    )
    if room.state == "readyToFinalize":
        room.state = "resolving"
    return True


def _dispute_id(payload: dict[str, Any]) -> str:
    """Clients may propose the dispute identifier (for optimistic UI); otherwise one is generated."""
    proposed = payload.get("disputeId")
    return require_uuid(proposed, "disputeId") if proposed is not None else new_id()


def _resolve(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    dispute_id = require_uuid(payload.get("disputeId"), "disputeId")
    status = payload.get("status")
    if status not in ("resolved", "dismissed"):
        raise DomainError("invalid_payload", "status must be resolved or dismissed")
    dispute = next((d for d in room.disputes if d.id == dispute_id), None)
    if dispute is None:
        raise DomainError("dispute_not_found", "That dispute is no longer open")
    if not dispute.is_open:
        raise DomainError("dispute_already_resolved", "This dispute was already resolved")
    note = optional_note(payload.get("note"))
    if status == "dismissed" and note is None:
        raise DomainError("note_required", "Add a short note explaining why no change is needed")
    dispute.status = status
    dispute.resolved_by = actor.participant_id
    dispute.resolved_at = now
    dispute.resolution_note = note
    return True


def _mark_reviewed(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    room.reviews[actor.participant_id] = room.revision + 1
    # The share this review covers: a later change to it makes the person unreviewed again.
    room.review_totals[actor.participant_id] = allocate(room).participant(actor.participant_id).total
    room.needs_review = [pid for pid in room.needs_review if pid != actor.participant_id]
    return True


def _payer_accepts(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    accepts = payload.get("accepts")
    if not isinstance(accepts, bool):
        raise DomainError("invalid_payload", "accepts must be true or false")
    if room.payer_accepts_full_receipt == accepts:
        return False
    room.payer_accepts_full_receipt = accepts
    return True


def _set_charge_allocation(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    charge_id = require_uuid(payload.get("chargeId"), "chargeId")
    charge = room.receipt.charge(charge_id)
    if charge is None:
        raise DomainError("charge_not_found", "That charge is no longer on the receipt")
    allocation = ChargeAllocation.from_wire(payload.get("allocation"), max_amount)
    if allocation.to_wire() == charge.allocation.to_wire():
        return False
    previous = charge.allocation
    charge.allocation = allocation
    basis: dict[str, int] = {}
    for result in allocate(room).items:
        for pid, amount in result.shares:
            basis[pid] = basis.get(pid, 0) + amount
    preview = allocate_charge(charge, basis, room, room.participant_ids)
    if preview.status not in ("allocated", "noBasis"):
        charge.allocation = previous
        raise DomainError(
            "invalid_allocation", "That split doesn't add up to the charge", {"status": preview.status, "remaining": preview.remaining}
        )
    if room.state == "readyToFinalize":
        room.state = "resolving"
    return True


def _remove_participant(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    participant_id = require_uuid(payload.get("participantId"), "participantId")
    participant = room.participant(participant_id)
    if participant is None or not participant.is_active:
        raise DomainError("participant_not_in_room", "That person isn't in this room")
    if participant_id == room.host_participant_id:
        raise DomainError("forbidden", "The host can't leave their own room")
    participant.removed_at = now
    room.claims = [c for c in room.claims if c.participant_id != participant_id]
    room.reviews.pop(participant_id, None)
    room.review_totals.pop(participant_id, None)
    room.needs_review = [pid for pid in room.needs_review if pid != participant_id]
    if room.state == "readyToFinalize":
        room.state = "resolving"
    return True


def _revise(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    receipt = receipt_from_wire(payload.get("receipt"), max_amount)
    if receipt.currency != room.receipt.currency:
        raise DomainError("currency_change_after_open", "The currency can't change after the room opens")
    if receipt.to_wire() == room.receipt.to_wire():
        return False
    new_items = {item.id: item for item in receipt.items}
    old_ids = {item.id for item in room.receipt.items}
    removed = [item.id for item in room.receipt.items if item.id not in new_items]
    financial = [
        item.id
        for item in room.receipt.items
        if item.id in new_items and (new_items[item.id].line_total != item.line_total or new_items[item.id].is_refund != item.is_refund)
    ]
    affected = set(removed + financial)
    cleared = [c.participant_id for c in room.claims if c.item_id in affected]
    room.claims = [c for c in room.claims if c.item_id not in affected]
    for dispute in room.disputes:
        if dispute.is_open and dispute.target_kind == "item" and dispute.target_id in removed:
            dispute.status = "resolved"
            dispute.resolved_by = actor.participant_id
            dispute.resolved_at = now
            dispute.resolution_note = "Item removed from the receipt"
    needing = set(cleared)
    room.needs_review = [pid for pid in room.participant_ids if pid in needing or pid in room.needs_review]

    def charge_changed(new: Charge) -> bool:
        old = room.receipt.charge(new.id)
        return old is None or old.amount != new.amount or old.kind != new.kind

    charges_changed = any(charge_changed(c) for c in receipt.charges) or any(receipt.charge(c.id) is None for c in room.receipt.charges)
    added = [item.id for item in receipt.items if item.id not in old_ids]
    nonfinancial_only = not (financial or removed or added or charges_changed or receipt.total != room.receipt.total)
    room.receipt = receipt
    if room.state == "readyToFinalize" and not nonfinancial_only:
        room.state = "resolving"
    return True


def _transition(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    move = payload.get("move")
    if move == "beginResolving":
        if room.state != "open":
            raise DomainError("not_allowed_in_state", "That isn't possible right now", {"state": room.state})
        room.state = "resolving"
    elif move == "reopenClaims":
        if room.state != "resolving":
            raise DomainError("not_allowed_in_state", "That isn't possible right now", {"state": room.state})
        room.state = "open"
    elif move == "requestFinalReview":
        if room.state not in ("open", "resolving"):
            raise DomainError("not_allowed_in_state", "That isn't possible right now", {"state": room.state})
        issues = readiness_issues(room)
        if issues:
            raise DomainError("not_ready_to_finalize", "Some items or charges still need attention", {"issues": issues})
        room.state = "readyToFinalize"
    elif move == "returnToRoom":
        if room.state != "readyToFinalize":
            raise DomainError("not_allowed_in_state", "That isn't possible right now", {"state": room.state})
        room.state = "resolving"
    else:
        raise DomainError("invalid_payload", "Unknown move")
    return True


def _cancel(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    room.state = "cancelled"
    if room.is_temporary:
        room.closed_at = now
        room.end_reason = "cancelled"
    return True


def _acknowledged(payload: dict[str, Any]) -> set[str]:
    raw = payload.get("acknowledgeUnreviewed", [])
    if not isinstance(raw, list) or len(raw) > MAX_PARTICIPANTS:
        raise DomainError("invalid_payload", "acknowledgeUnreviewed must be a list of participants")
    return {require_uuid(value, "acknowledgeUnreviewed") for value in raw}


def _finalize(room: Room, actor: Actor, payload: dict[str, Any], now: str, max_amount: int) -> bool:
    allocation = allocate(room)
    issues = readiness_issues(room, allocation)
    if issues:
        code = "unresolved_dispute" if any(issue["kind"] == "openDispute" for issue in issues) else "not_ready_to_finalize"
        raise DomainError(code, "Some items or charges still need attention", {"issues": issues})
    if room.receipt.total is None or room.payer_id is None:
        raise DomainError("not_ready_to_finalize", "Some items or charges still need attention", {"issues": []})
    # Never finalize someone's share silently: in temporary rooms and group receipts, the host must
    # name every person who hasn't reviewed their current share. They're recorded as host-resolved.
    unreviewed = unreviewed_participants(room, allocation)
    acknowledged = _acknowledged(payload)
    if room.requires_reviews:
        missing = [pid for pid in unreviewed if pid not in acknowledged]
        if missing:
            raise DomainError(
                "unreviewed_shares",
                "Some people haven't reviewed their share. Wait for them, or finalize for them",
                {"participantIds": missing},
            )
    room.state = "finalized"
    room.finalization = Finalization(
        finalized_at=now,
        finalized_by=actor.participant_id,
        revision=room.revision + 1,
        participants=[p.to_wire() for p in allocation.participants],
        items=[
            {
                "id": item.id,
                "name": item.name,
                "quantity": item.quantity,
                "lineTotal": item.line_total,
                "isRefund": item.is_refund,
                "shares": [
                    {"participantId": pid, "amount": amount}
                    for pid, amount in (allocation.item(item.id) or ItemResult(item.id, "unclaimed")).shares
                ],
            }
            for item in room.receipt.items
        ],
        charges=[
            {
                "id": charge.id,
                "kind": charge.kind,
                "label": charge.label,
                "amount": charge.amount,
                "allocation": charge.allocation.to_wire(),
                "shares": [
                    {"participantId": pid, "amount": amount}
                    for pid, amount in (allocation.charge(charge.id) or ChargeResult(charge.id, "noBasis")).shares
                ],
            }
            for charge in room.receipt.charges
        ],
        rounding=[
            {"source": {"kind": "item", "id": result.item_id}, "participantId": pid, "amount": amount}
            for result in allocation.items
            for pid, amount in result.rounding
        ]
        + [
            {"source": {"kind": "charge", "id": result.charge_id}, "participantId": pid, "amount": amount}
            for result in allocation.charges
            for pid, amount in result.rounding
        ],
        payments=[{"participantId": room.payer_id, "amount": room.receipt.total}],
        total=room.receipt.total,
        host_resolved=[pid for pid in unreviewed if pid in acknowledged or not room.requires_reviews],
    )
    if room.is_temporary:
        room.payments = obligations_after_finalization(room)
        if not room.payments:
            # Nobody owes the payer anything: the room is square the moment it's finalized.
            room.closed_at = now
            room.end_reason = "allSquare"
    return True


_HANDLERS = {
    "claim": _claim,
    "unclaim": _unclaim,
    "claimUnits": _claim_units,
    "setItemSplit": _set_split,
    "dispute": _dispute,
    "resolveDispute": _resolve,
    "markReviewed": _mark_reviewed,
    "setPayerAcceptsFullReceipt": _payer_accepts,
    "setChargeAllocation": _set_charge_allocation,
    "removeParticipant": _remove_participant,
    "reviseReceipt": _revise,
    "transition": _transition,
    "cancel": _cancel,
    "finalize": _finalize,
}
