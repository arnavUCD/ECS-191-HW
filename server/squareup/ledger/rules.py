"""Pure money rules for shared groups — direct ports of the Swift implementations.

| Python | Swift |
|---|---|
| :func:`split_equal`, :func:`split_shares`, :func:`split_percentage` | ``SplitCalculator`` |
| :func:`validate_expense` | ``ExpenseValidator`` (+ the inactive-participant rule in ``LedgerEngine``) |
| :class:`GroupLedger`, :func:`group_ledger` | ``GroupLedger``, ``BalanceCalculator`` |
| :func:`settlement_plan` | ``SettlementPlanner`` |
| :func:`apply_attempt_action` | ``PaymentAttemptMachine`` |

Every amount is an ``int`` in minor units. Every function is deterministic: the same input
produces the same output on every server and every iPhone (``HW/Shared/parity-fixtures``).
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from typing import Any

from ..domain.errors import DomainError
from ..domain.money import distribute

#: Percentages may carry at most this many fraction digits ("33.3333").
PERCENT_FRACTION_DIGITS = 4

ATTEMPT_STATES = ("methodSelected", "handoffOpened", "reportedSent", "confirmed", "rejected", "disputed", "cancelled")
DRAFT_STATES = ("methodSelected", "handoffOpened")
RESERVING_STATES = ("reportedSent", "disputed")
TERMINAL_STATES = ("confirmed", "rejected", "cancelled")


# MARK: - Splits


def _require_participants(total: int, participants: Sequence[str]) -> None:
    if total <= 0:
        raise DomainError("invalid_split", "The amount must be more than zero")
    if not participants:
        raise DomainError("invalid_split", "Choose who shares this")
    if len(set(participants)) != len(participants):
        raise DomainError("invalid_split", "Someone is listed twice")


def split_equal(total: int, participants: Sequence[str]) -> list[tuple[str, int]]:
    """``SplitCalculator.equal``: largest remainder, ties by the order given."""
    _require_participants(total, participants)
    units = distribute(total, [1] * len(participants)).units
    return list(zip(participants, units, strict=True))


def split_shares(total: int, weights: Sequence[tuple[str, int]]) -> list[tuple[str, int]]:
    """``SplitCalculator.shares``."""
    _require_participants(total, [member for member, _ in weights])
    if any(weight < 0 for _, weight in weights):
        raise DomainError("invalid_split", "Shares can't be negative")
    if not any(weight > 0 for _, weight in weights):
        raise DomainError("invalid_split", "At least one person needs a share")
    units = distribute(total, [weight for _, weight in weights]).units
    return [(member, amount) for (member, _), amount in zip(weights, units, strict=True)]


def parse_percent(raw: object) -> Decimal:
    """A percentage as a plain decimal string ("33.34"), at most four fraction digits."""
    if not isinstance(raw, str) or not 1 <= len(raw) <= 12:
        raise DomainError("invalid_payload", "Percentages must be decimal strings")
    try:
        value = Decimal(raw)
    except InvalidOperation as error:
        raise DomainError("invalid_payload", "Percentages must be decimal strings") from error
    if not value.is_finite():
        raise DomainError("invalid_payload", "Percentages must be decimal strings")
    exponent = value.as_tuple().exponent
    if isinstance(exponent, int) and -exponent > PERCENT_FRACTION_DIGITS:
        raise DomainError("invalid_split", "Use at most four decimal places in a percentage")
    return value


def split_percentage(total: int, percentages: Sequence[tuple[str, Decimal]]) -> list[tuple[str, int]]:
    """``SplitCalculator.percentage``: must total exactly 100; weights scaled to exact integers."""
    _require_participants(total, [member for member, _ in percentages])
    if any(percent < 0 for _, percent in percentages):
        raise DomainError("invalid_split", "Percentages can't be negative")
    if sum((percent for _, percent in percentages), Decimal(0)) != 100:
        raise DomainError("invalid_split", "Percentages must add up to 100")
    scale = Decimal(10) ** PERCENT_FRACTION_DIGITS
    weights = [int(percent * scale) for _, percent in percentages]
    units = distribute(total, weights).units
    return [(member, amount) for (member, _), amount in zip(percentages, units, strict=True)]


# MARK: - Expenses


def validate_expense(expense: dict[str, Any], *, group_member_ids: Iterable[str], participating_ids: Iterable[str]) -> None:
    """``ExpenseValidator.validate`` plus the engine's inactive-participant rule.

    ``group_member_ids``: everyone who ever belonged to the group. ``participating_ids``: people
    who may appear in this revision (active and pending seats, plus anyone already in the previous
    revision of an edited expense).
    """
    if not expense["title"].strip():
        raise DomainError("invalid_expense", "Add a description", {"reason": "emptyTitle"})
    total = expense["total"]
    if total <= 0:
        raise DomainError("invalid_expense", "The amount must be more than zero", {"reason": "nonPositiveTotal"})
    payments: list[dict[str, Any]] = expense["payments"]
    allocations: list[dict[str, Any]] = expense["allocations"]
    if not payments:
        raise DomainError("invalid_expense", "Choose who paid", {"reason": "noPayer"})
    if any(share["amount"] < 0 for share in payments + allocations):
        raise DomainError("invalid_expense", "Amounts can't be negative", {"reason": "negativeShare"})
    known = set(group_member_ids)
    allowed = set(participating_ids)
    for share in payments + allocations:
        if share["memberId"] not in known:
            raise DomainError("invalid_expense", "Someone isn't in this group", {"reason": "participantNotInGroup"})
        if share["memberId"] not in allowed:
            raise DomainError("inactive_participant", "Someone in this expense is no longer in the group", {"memberId": share["memberId"]})
    paid = sum(share["amount"] for share in payments)
    if paid != total:
        raise DomainError(
            "invalid_expense",
            "What people paid doesn't add up to the total",
            {"reason": "paymentsDoNotReconcile", "remaining": total - paid},
        )
    if not allocations:
        raise DomainError("invalid_expense", "Choose who shares this", {"reason": "noParticipants"})
    allocated = sum(share["amount"] for share in allocations)
    if allocated != total:
        raise DomainError(
            "invalid_expense",
            "The split doesn't add up to the total",
            {"reason": "allocationsDoNotReconcile", "remaining": total - allocated},
        )


def recompute_split(total: int, split: dict[str, Any]) -> list[tuple[str, int]]:
    """The canonical allocation for a split the client described (equal, shares, percentage)."""
    method = split["method"]
    if method == "equal":
        return split_equal(total, split["participants"])
    if method == "shares":
        return split_shares(total, [(entry["memberId"], entry["weight"]) for entry in split["weights"]])
    if method == "percentage":
        return split_percentage(total, [(entry["memberId"], entry["percent"]) for entry in split["percentages"]])
    raise DomainError("invalid_payload", "Unknown split method")


# MARK: - Balances


@dataclass
class GroupLedger:
    """``GroupLedger``: gross minor units each debtor owes each creditor, before netting."""

    member_ids: list[str]
    gross: dict[tuple[str, str], int] = field(default_factory=dict)

    def net_owed(self, debtor: str, creditor: str) -> int:
        return self.gross.get((debtor, creditor), 0) - self.gross.get((creditor, debtor), 0)

    def net(self, member: str) -> int:
        units = 0
        for (debtor, creditor), value in self.gross.items():
            if creditor == member:
                units += value
            if debtor == member:
                units -= value
        return units


def group_ledger(member_ids: list[str], expenses: Iterable[dict[str, Any]], settlements: Iterable[dict[str, Any]]) -> GroupLedger:
    """``BalanceCalculator.ledger``: allocations are owed to payers in proportion to what they paid
    (largest remainder); a settlement reduces what the payer owed the recipient."""
    ledger = GroupLedger(member_ids=list(member_ids))
    for expense in expenses:
        if expense.get("deletedAt"):
            continue
        payments = expense["payments"]
        weights = [payment["amount"] for payment in payments]
        for allocation in expense["allocations"]:
            portions = distribute(allocation["amount"], weights).units
            for payment, units in zip(payments, portions, strict=True):
                if payment["memberId"] != allocation["memberId"] and units != 0:
                    key = (allocation["memberId"], payment["memberId"])
                    ledger.gross[key] = ledger.gross.get(key, 0) + units
    for settlement in settlements:
        key = (settlement["toId"], settlement["fromId"])
        ledger.gross[key] = ledger.gross.get(key, 0) + settlement["amount"]
    return ledger


# MARK: - Settlement plan


@dataclass(frozen=True)
class Transfer:
    payer: str
    recipient: str
    amount: int

    def to_wire(self) -> dict[str, Any]:
        return {"payerId": self.payer, "recipientId": self.recipient, "amount": self.amount}


def direct_transfers(ledger: GroupLedger, order: list[str]) -> list[Transfer]:
    """``SettlementPlanner.directTransfers``: one payment per pair with a non-zero net."""
    transfers: list[Transfer] = []
    for index, first in enumerate(order):
        for second in order[index + 1 :]:
            owed = ledger.net_owed(first, second)
            if owed > 0:
                transfers.append(Transfer(first, second, owed))
            if owed < 0:
                transfers.append(Transfer(second, first, -owed))
    return transfers


def simplified_transfers(nets: dict[str, int], order: list[str]) -> list[Transfer]:
    """``SettlementPlanner.simplifiedTransfers``: exact matches, then largest debtor → largest
    creditor; ties by membership order; at most n − 1 payments; every net preserved."""
    rank = {member: index for index, member in enumerate(order)}
    debtors: list[list[Any]] = [[member, -nets[member]] for member in order if nets.get(member, 0) < 0]
    creditors: list[list[Any]] = [[member, nets[member]] for member in order if nets.get(member, 0) > 0]
    transfers: list[Transfer] = []

    index = 0
    while index < len(debtors):
        match = next((position for position, creditor in enumerate(creditors) if creditor[1] == debtors[index][1]), None)
        if match is not None:
            transfers.append(Transfer(str(debtors[index][0]), str(creditors[match][0]), int(debtors[index][1])))
            debtors.pop(index)
            creditors.pop(match)
        else:
            index += 1

    def largest(entries: list[list[Any]]) -> int | None:
        if not entries:
            return None
        # Largest amount; among equals, the earliest member in membership order.
        return min(range(len(entries)), key=lambda position: (-entries[position][1], rank[entries[position][0]]))

    while (debtor := largest(debtors)) is not None and (creditor := largest(creditors)) is not None:
        units = min(int(debtors[debtor][1]), int(creditors[creditor][1]))
        transfers.append(Transfer(str(debtors[debtor][0]), str(creditors[creditor][0]), int(units)))
        debtors[debtor][1] -= units
        creditors[creditor][1] -= units
        if debtors[debtor][1] == 0:
            debtors.pop(debtor)
        zero = next((position for position, entry in enumerate(creditors) if entry[1] == 0), None)
        if zero is not None:
            creditors.pop(zero)

    return sorted(transfers, key=lambda transfer: (rank[transfer.payer], rank[transfer.recipient]))


@dataclass
class SettlementPlan:
    simplified: bool
    payments: list[Transfer]
    direct_count: int
    simplified_count: int
    pending_attempt_ids: list[str]
    confirmed_nets: dict[str, int]
    available_nets: dict[str, int]

    def payment(self, payer: str, recipient: str) -> Transfer | None:
        return next((p for p in self.payments if p.payer == payer and p.recipient == recipient), None)

    def to_wire(self) -> dict[str, Any]:
        return {
            "simplified": self.simplified,
            "payments": [payment.to_wire() for payment in self.payments],
            "directPaymentCount": self.direct_count,
            "simplifiedPaymentCount": self.simplified_count,
            "pendingAttemptIds": self.pending_attempt_ids,
            "confirmedNets": self.confirmed_nets,
            "availableNets": self.available_nets,
        }


def attempt_created_at(attempt: dict[str, Any]) -> str:
    history: list[dict[str, Any]] = attempt["history"]
    return str(history[0]["at"]) if history else ""


def settlement_plan(
    member_ids: list[str],
    expenses: list[dict[str, Any]],
    settlements: list[dict[str, Any]],
    attempts: list[dict[str, Any]],
    simplify: bool,
) -> SettlementPlan:
    """``SettlementPlanner.plan``: confirmed nets, and the actionable plan from *available* nets
    (reported and disputed attempts reserved as if paid, so they're never suggested twice)."""
    active_expenses = [expense for expense in expenses if not expense.get("deletedAt")]
    pending = sorted(
        (attempt for attempt in attempts if attempt["state"] in RESERVING_STATES),
        key=lambda attempt: (attempt_created_at(attempt), attempt["id"]),
    )
    confirmed = group_ledger(member_ids, active_expenses, settlements)
    reservations = [{"fromId": a["payerId"], "toId": a["recipientId"], "amount": a["amount"]} for a in pending]
    available = group_ledger(member_ids, active_expenses, settlements + reservations)
    direct = direct_transfers(available, member_ids)
    nets = {member: available.net(member) for member in member_ids}
    simplified = simplified_transfers(nets, member_ids)
    return SettlementPlan(
        simplified=simplify,
        payments=simplified if simplify else direct,
        direct_count=len(direct),
        simplified_count=len(simplified),
        pending_attempt_ids=[attempt["id"] for attempt in pending],
        confirmed_nets={member: confirmed.net(member) for member in member_ids},
        available_nets=nets,
    )


# MARK: - Payment attempts


def apply_attempt_action(attempt: dict[str, Any], action: str, actor: str, now: str, note: str | None = None) -> bool:
    """``PaymentAttemptMachine.apply``. Mutates ``attempt``; returns False for an idempotent repeat.

    ```text
    methodSelected → handoffOpened → reportedSent → confirmed
    methodSelected/handoffOpened → reportedSent
    methodSelected/handoffOpened/reportedSent → cancelled   (payer, before confirmation)
    reportedSent → rejected | disputed
    disputed → confirmed | rejected
    ```
    """
    is_payer = actor == attempt["payerId"]
    is_recipient = actor == attempt["recipientId"]
    state = attempt["state"]

    def move(next_state: str, transition_note: str | None = None) -> bool:
        attempt["state"] = next_state
        attempt["history"].append({"state": next_state, "actorId": actor, "at": now, "note": transition_note})
        return True

    def refuse() -> DomainError:
        return DomainError("not_allowed_in_state", "That can't be done to this payment now", {"state": state, "action": action})

    if action == "openHandoff":
        if not is_payer:
            raise DomainError("forbidden", "Only the person paying can do that")
        if state == "methodSelected":
            return move("handoffOpened")
        if state == "handoffOpened":
            return False
        raise refuse()
    if action == "reportSent":
        if not is_payer:
            raise DomainError("forbidden", "Only the person paying can do that")
        if state in DRAFT_STATES:
            return move("reportedSent")
        if state == "reportedSent":
            return False
        raise refuse()
    if action == "confirm":
        if not is_recipient:
            raise DomainError("forbidden", "Only the person receiving the money can confirm it")
        if state in RESERVING_STATES:
            return move("confirmed")
        if state == "confirmed":
            return False
        raise refuse()
    if action == "reject":
        if not is_recipient:
            raise DomainError("forbidden", "Only the person receiving the money can say it didn't arrive")
        if state in RESERVING_STATES:
            return move("rejected", note)
        if state == "rejected":
            return False
        raise refuse()
    if action == "dispute":
        if not (is_payer or is_recipient):
            raise DomainError("forbidden", "Only the two people in this payment can dispute it")
        if state == "reportedSent":
            return move("disputed", note)
        if state == "disputed":
            return False
        raise refuse()
    if action == "cancel":
        if not is_payer:
            raise DomainError("forbidden", "Only the person paying can cancel")
        if state in (*DRAFT_STATES, "reportedSent"):
            return move("cancelled", note)
        if state == "cancelled":
            return False
        raise refuse()
    raise DomainError("invalid_payload", "Unknown payment action")
