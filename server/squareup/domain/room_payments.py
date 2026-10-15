"""Settling up inside a temporary room ("Split with people now").

After the host finalizes, each participant who owes the payer has one obligation for exactly their
finalized total. Square Up never moves money: a participant *reports* that they paid outside the
app (Venmo, cash, …) and only the payer — the recipient — can confirm or reject it. The transitions
are the shared-group payment machine (:func:`ledger.rules.apply_attempt_action`), so a room payment
follows the same rules as a group payment: report → confirm/reject, either side may dispute a
report, the payer of a report may cancel it before confirmation, and a repeat changes nothing.

When every obligation is confirmed the room is square and closes on its own.
"""

from __future__ import annotations

from typing import Any

from ..ledger.rules import apply_attempt_action
from .errors import DomainError
from .room import Room, new_id, require_text, require_uuid

PAYMENT_COMMANDS = frozenset({"reportPayment", "cancelPaymentReport", "confirmPayment", "rejectPayment", "disputePayment"})
#: Payment methods a participant may say they used (the shared-group providers).
PROVIDERS = ("appleCash", "paypal", "cashApp", "zelle", "venmo", "cash", "other")
MAX_REFERENCE = 60
MAX_REASON = 140
MAX_ATTEMPTS_PER_PAYMENT = 20


def obligations_after_finalization(room: Room) -> list[dict[str, Any]]:
    """One obligation per person who owes the payer something, from the finalization itself."""
    if room.finalization is None or room.payer_id is None:
        return []
    return [
        {"participantId": entry["participantId"], "amount": int(entry["total"]), "state": "owed", "attempts": []}
        for entry in room.finalization.participants
        if entry["participantId"] != room.payer_id and int(entry["total"]) > 0
    ]


def _payment(room: Room, participant_id: str) -> dict[str, Any] | None:
    return next((payment for payment in room.payments if payment["participantId"] == participant_id), None)


def _optional_text(value: object, field_name: str, max_length: int) -> str | None:
    if value is None:
        return None
    text = require_text(value, field_name, max_length=max_length, allow_empty=True)
    return text or None


def apply_payment_command(room: Room, actor_id: str, command_type: str, payload: dict[str, Any], now: str) -> bool:
    """Mutates ``room`` (a working copy). Returns False for an idempotent repeat."""
    if not room.is_temporary:
        raise DomainError("not_allowed_in_state", "Payments are recorded in the group for this receipt", {"state": room.state})
    if room.state != "finalized":
        raise DomainError("not_allowed_in_state", "Payments start once the host finalizes the split", {"state": room.state})
    if command_type in ("reportPayment", "cancelPaymentReport"):
        payment = _payment(room, actor_id)
        if payment is None:
            raise DomainError("no_payment_due", "You don't owe anything on this receipt")
    else:
        payment = _payment(room, require_uuid(payload.get("participantId"), "participantId"))
        if payment is None:
            raise DomainError("payment_not_found", "That payment isn't on this receipt")
    attempts: list[dict[str, Any]] = payment["attempts"]
    current = attempts[-1] if attempts else None

    if command_type == "reportPayment":
        if payment["state"] in ("reportedSent", "disputed"):
            return False  # already reported: a retry or second tap changes nothing
        if payment["state"] == "confirmed":
            raise DomainError("not_allowed_in_state", "This payment was already confirmed", {"state": payment["state"]})
        if len(attempts) >= MAX_ATTEMPTS_PER_PAYMENT:
            raise DomainError(
                "not_allowed_in_state", "Ask the payer to confirm this payment with you directly", {"state": payment["state"]}
            )
        provider = payload.get("provider", "other")
        if provider not in PROVIDERS:
            raise DomainError("invalid_payload", "Unknown payment method")
        destination_id = payload.get("destinationId")
        if destination_id is not None:
            destination_id = require_uuid(destination_id, "destinationId")
            if destination_id not in room.destination_ids:
                raise DomainError("destination_unavailable", "That payment method isn't available anymore")
        proposed = payload.get("paymentId")
        attempt = {
            "id": require_uuid(proposed, "paymentId") if proposed is not None else new_id(),
            "payerId": actor_id,
            "recipientId": room.payer_id,
            "amount": payment["amount"],
            "provider": provider,
            "destinationId": destination_id,
            "state": "methodSelected",
            "history": [{"state": "methodSelected", "actorId": actor_id, "at": now, "note": None}],
            "externalReference": _optional_text(payload.get("reference"), "reference", MAX_REFERENCE),
        }
        apply_attempt_action(attempt, "reportSent", actor_id, now)
        attempts.append(attempt)
        payment["state"] = "reportedSent"
        return True

    if current is None:
        raise DomainError("not_allowed_in_state", "Nothing has been reported for this payment yet", {"state": payment["state"]})
    if command_type == "cancelPaymentReport":
        if not apply_attempt_action(current, "cancel", actor_id, now, "payerCancelled"):
            return False
        payment["state"] = "owed"
        return True
    if command_type == "confirmPayment":
        if not apply_attempt_action(current, "confirm", actor_id, now):
            return False
        payment["state"] = "confirmed"
        payment["confirmedAt"] = now
        if all(entry["state"] == "confirmed" for entry in room.payments):
            room.closed_at = now
            room.end_reason = "allSquare"
        return True
    if command_type == "rejectPayment":
        if not apply_attempt_action(current, "reject", actor_id, now, _optional_text(payload.get("reason"), "reason", MAX_REASON)):
            return False
        payment["state"] = "owed"  # they can report it again once it really arrives
        return True
    # disputePayment
    if not apply_attempt_action(current, "dispute", actor_id, now, _optional_text(payload.get("reason"), "reason", MAX_REASON)):
        return False
    payment["state"] = "disputed"
    return True
