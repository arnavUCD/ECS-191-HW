"""Receipt validation and finalization readiness — ports of `ReceiptValidator` and
`ReceiptRoomReadiness` from the iOS app (blocking issues only; the server never needs warnings).

Issue order matches Swift so parity fixtures can compare the lists exactly.
"""

from __future__ import annotations

from typing import Any

from .allocation import Allocation, allocate
from .room import Receipt, Room


def receipt_blocking_issues(receipt: Receipt) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    if not receipt.merchant.strip():
        issues.append({"kind": "merchantMissing"})
    if not any(not item.is_note for item in receipt.items):
        issues.append({"kind": "noItems"})
    for item in receipt.items:
        if not item.name.strip():
            issues.append({"kind": "itemNameBlank", "itemId": item.id})
        if item.quantity is not None and item.quantity <= 0:
            issues.append({"kind": "itemQuantityInvalid", "itemId": item.id})
        if item.line_total < 0 and not item.is_refund:
            issues.append({"kind": "negativeItemNotMarkedRefund", "itemId": item.id})
        if item.is_refund and not item.line_total < 0:
            issues.append({"kind": "refundNotNegative", "itemId": item.id})
    for charge in receipt.charges:
        if charge.amount == 0:
            issues.append({"kind": "chargeZero", "chargeId": charge.id})
        elif (charge.sign > 0 and charge.amount < 0) or (charge.sign < 0 and charge.amount > 0):
            issues.append({"kind": "chargeSignInvalid", "chargeId": charge.id})
        if charge.kind == "adjustment" and not charge.label.strip():
            issues.append({"kind": "adjustmentLabelMissing", "chargeId": charge.id})
    computed = sum(item.line_total for item in receipt.items) + sum(charge.amount for charge in receipt.charges)
    if receipt.total is None:
        issues.append({"kind": "totalMissing"})
    else:
        if receipt.total <= 0:
            issues.append({"kind": "totalNotPositive"})
        if receipt.total != computed:
            issues.append({"kind": "totalMismatch", "difference": receipt.total - computed})
    return issues


def readiness_issues(room: Room, allocation: Allocation | None = None) -> list[dict[str, Any]]:
    """`ReceiptRoomReadiness.issues` with the room's participants as the group context."""
    allocation = allocation or allocate(room)
    issues: list[dict[str, Any]] = []
    receipt_issues = receipt_blocking_issues(room.receipt)
    issues += [{"kind": "receipt", "issue": issue} for issue in receipt_issues]
    active = set(room.participant_ids)
    if room.payer_id is None:
        issues.append({"kind": "payerMissing"})
    elif room.payer_id not in active:
        issues.append({"kind": "payerNotInGroup", "participantId": room.payer_id})
    for result in allocation.items:
        if result.status in ("note", "allocated"):
            continue
        if result.status == "unclaimed":
            issues.append({"kind": "unclaimedItem", "itemId": result.item_id})
        elif result.status == "partial":
            issues.append({"kind": "partiallyAssignedItem", "itemId": result.item_id, "remaining": result.remaining})
        else:
            issues.append({"kind": "invalidItemSplit", "itemId": result.item_id, "reason": result.reason})
    for charge in allocation.charges:
        if not charge.is_allocated:
            issues.append({"kind": "unallocatedCharge", "chargeId": charge.charge_id, "status": charge.status})
    issues += [{"kind": "openDispute", "disputeId": dispute.id} for dispute in room.open_disputes]
    reconciled = not any(issue["kind"] == "totalMismatch" for issue in receipt_issues) and room.receipt.total is not None
    remaining = allocation.remaining
    if remaining is not None and remaining != 0 and reconciled:
        issues.append({"kind": "totalsDoNotMatch", "remaining": remaining})
    for participant in allocation.participants:
        if participant.total < 0:
            issues.append({"kind": "negativeParticipantTotal", "participantId": participant.participant_id, "total": participant.total})
    owing = [p for p in allocation.participants if p.total != 0 and p.participant_id != room.payer_id]
    if not issues and not owing and not room.payer_accepts_full_receipt:
        issues.append({"kind": "onlyPayerOwes"})
    return issues


def unreviewed_participants(room: Room, allocation: Allocation | None = None) -> list[str]:
    """Active participants (other than the host) who haven't reviewed their current share.

    A review counts only while the share it saw is unchanged: if someone later shares an item the
    person claimed, or the host edits the receipt, their share is unreviewed again. Not a readiness
    issue — the host may still finalize, but only by acknowledging each of these people."""
    allocation = allocation or allocate(room)
    unreviewed: list[str] = []
    for participant_id in room.participant_ids:
        if participant_id == room.host_participant_id:
            continue
        total = allocation.participant(participant_id).total
        reviewed = (
            participant_id in room.reviews
            and participant_id not in room.needs_review
            and room.review_totals.get(participant_id, total) == total
        )
        if not reviewed:
            unreviewed.append(participant_id)
    return unreviewed
