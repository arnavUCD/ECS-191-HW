"""Authoritative itemized allocation — a direct port of the Swift `ReceiptAllocationEngine`.

All division goes through :func:`money.divide_signed` (largest remainder, ties by room participant
order). Shared parity fixtures (``HW/Shared/parity-fixtures``) prove the Swift and Python results
match exactly.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .money import divide_signed
from .room import Charge, Claim, Item, Room


@dataclass
class ItemResult:
    item_id: str
    status: str  # note | unclaimed | allocated | partial | invalid
    shares: list[tuple[str, int]] = field(default_factory=list)
    rounding: list[tuple[str, int]] = field(default_factory=list)
    claimants: list[str] = field(default_factory=list)
    remaining: int | None = None
    reason: str | None = None  # mixedModes | exceeds | zeroWeights | notAParticipant | wrongSign
    reason_amount: int | None = None
    reason_participant: str | None = None

    @property
    def is_resolved(self) -> bool:
        return self.status in ("allocated", "note")

    def to_wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {
            "itemId": self.item_id,
            "status": self.status,
            "claimants": self.claimants,
            "shares": [{"participantId": pid, "amount": amount} for pid, amount in self.shares],
            "rounding": [{"participantId": pid, "amount": amount} for pid, amount in self.rounding],
        }
        if self.status == "partial":
            wire["remaining"] = self.remaining
        if self.status == "invalid":
            wire["reason"] = {"kind": self.reason, "amount": self.reason_amount, "participantId": self.reason_participant}
        return wire


@dataclass
class ChargeResult:
    charge_id: str
    status: str  # allocated | noBasis | exactMismatch | noRecipients | payerMissing | notAParticipant
    shares: list[tuple[str, int]] = field(default_factory=list)
    rounding: list[tuple[str, int]] = field(default_factory=list)
    remaining: int | None = None
    participant: str | None = None

    @property
    def is_allocated(self) -> bool:
        return self.status == "allocated"

    def to_wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {
            "chargeId": self.charge_id,
            "status": self.status,
            "shares": [{"participantId": pid, "amount": amount} for pid, amount in self.shares],
            "rounding": [{"participantId": pid, "amount": amount} for pid, amount in self.rounding],
        }
        if self.remaining is not None:
            wire["remaining"] = self.remaining
        if self.participant is not None:
            wire["participantId"] = self.participant
        return wire


@dataclass
class ParticipantTotal:
    participant_id: str
    items: int = 0
    tax: int = 0
    tip: int = 0
    fees: int = 0
    discounts: int = 0
    adjustments: int = 0
    item_shares: list[tuple[str, int]] = field(default_factory=list)

    @property
    def total(self) -> int:
        return self.items + self.tax + self.tip + self.fees + self.discounts + self.adjustments

    def to_wire(self) -> dict[str, Any]:
        return {
            "participantId": self.participant_id,
            "items": self.items,
            "tax": self.tax,
            "tip": self.tip,
            "fees": self.fees,
            "discounts": self.discounts,
            "adjustments": self.adjustments,
            "total": self.total,
            "itemShares": [{"itemId": item_id, "amount": amount} for item_id, amount in self.item_shares],
        }


@dataclass
class Allocation:
    receipt_total: int | None
    items: list[ItemResult]
    charges: list[ChargeResult]
    participants: list[ParticipantTotal]

    @property
    def allocated_total(self) -> int:
        return sum(p.total for p in self.participants)

    @property
    def remaining(self) -> int | None:
        return None if self.receipt_total is None else self.receipt_total - self.allocated_total

    @property
    def is_complete(self) -> bool:
        return all(i.is_resolved for i in self.items) and all(c.is_allocated for c in self.charges) and self.remaining == 0

    def item(self, item_id: str) -> ItemResult | None:
        return next((i for i in self.items if i.item_id == item_id), None)

    def charge(self, charge_id: str) -> ChargeResult | None:
        return next((c for c in self.charges if c.charge_id == charge_id), None)

    def participant(self, participant_id: str) -> ParticipantTotal:
        return next((p for p in self.participants if p.participant_id == participant_id), ParticipantTotal(participant_id))

    def to_wire(self) -> dict[str, Any]:
        return {
            "receiptTotal": self.receipt_total,
            "allocatedTotal": self.allocated_total,
            "remaining": self.remaining,
            "isComplete": self.is_complete,
            "items": [i.to_wire() for i in self.items],
            "charges": [c.to_wire() for c in self.charges],
            "participants": [p.to_wire() for p in self.participants],
        }


def _order_index(order: list[str], participant_id: str) -> int:
    try:
        return order.index(participant_id)
    except ValueError:
        return len(order) + 1


def allocate_item(item: Item, claims: list[Claim], participants: set[str], order: list[str]) -> ItemResult:
    sorted_claims = sorted(claims, key=lambda c: _order_index(order, c.participant_id))
    claimants = [c.participant_id for c in sorted_claims]

    def result(status: str, **kwargs: Any) -> ItemResult:
        return ItemResult(item.id, status, claimants=claimants, **kwargs)

    if item.is_note:
        return result("note")
    if not sorted_claims:
        return result("unclaimed")
    outsider = next((pid for pid in claimants if pid not in participants), None)
    if outsider is not None:
        return result("invalid", reason="notAParticipant", reason_participant=outsider)

    amount = item.line_total
    exacts = [(c.participant_id, c.mode.amount or 0) for c in sorted_claims if c.mode.kind == "exact"]
    if exacts:
        if len(exacts) != len(sorted_claims):
            return result("invalid", reason="mixedModes")
        if not all(value == 0 or (value < 0) == (amount < 0) for _, value in exacts):
            return result("invalid", reason="wrongSign")
        assigned = sum(value for _, value in exacts)
        if assigned == amount:
            return result("allocated", shares=exacts)
        remaining = amount - assigned
        if (remaining < 0) != (amount < 0):
            return result("invalid", reason="exceeds", reason_amount=abs(remaining))
        return result("partial", shares=exacts, remaining=remaining)

    if any(c.mode.kind == "units" for c in sorted_claims):
        return _allocate_units(item, sorted_claims, claimants, result)

    weights = [max(c.mode.shares or 0, 0) if c.mode.kind == "shares" else 1 for c in sorted_claims]
    if not any(weight > 0 for weight in weights):
        return result("invalid", reason="zeroWeights")
    units, bumped = divide_signed(amount, weights)
    sign = -1 if amount < 0 else 1
    shares = list(zip(claimants, units, strict=True))
    rounding = [(claimants[i], sign) for i in range(len(claimants)) if i in bumped]
    return result("allocated", shares=shares, rounding=rounding)


def _allocate_units(item: Item, claims: list[Claim], claimants: list[str], result: Any) -> ItemResult:
    """Unit claims ("2 of the 3 beers"): each person pays for their units of the line, divided by
    largest remainder over the printed quantity. Units nobody claimed stay unassigned (``partial``),
    never silently spread over the people who did claim."""
    if any(c.mode.kind != "units" for c in claims):
        return result("invalid", reason="mixedModes")  # type: ignore[no-any-return]
    quantity = item.quantity
    if quantity is None or quantity < 1:
        return result("invalid", reason="noQuantity")  # type: ignore[no-any-return]
    counts = [max(c.mode.units or 0, 0) for c in claims]
    claimed = sum(counts)
    if claimed > quantity:
        return result("invalid", reason="unitsExceed", reason_amount=claimed - quantity)  # type: ignore[no-any-return]
    if claimed == 0:
        return result("invalid", reason="zeroWeights")  # type: ignore[no-any-return]
    unclaimed = quantity - claimed
    amounts, bumped = divide_signed(item.line_total, counts + ([unclaimed] if unclaimed else []))
    shares = list(zip(claimants, amounts[: len(claimants)], strict=True))
    if unclaimed:
        return result("partial", shares=shares, remaining=amounts[-1])  # type: ignore[no-any-return]
    sign = -1 if item.line_total < 0 else 1
    rounding = [(claimants[i], sign) for i in range(len(claimants)) if i in bumped]
    return result("allocated", shares=shares, rounding=rounding)  # type: ignore[no-any-return]


def allocate_charge(charge: Charge, basis: dict[str, int], room: Room, order: list[str]) -> ChargeResult:
    amount = charge.amount
    participants = set(order)
    allocation = charge.allocation
    sign = -1 if amount < 0 else 1

    def divided(recipients: list[str], weights: list[int]) -> ChargeResult:
        units, bumped = divide_signed(amount, weights)
        return ChargeResult(
            charge.id,
            "allocated",
            shares=list(zip(recipients, units, strict=True)),
            rounding=[(recipients[i], sign) for i in range(len(recipients)) if i in bumped],
        )

    if allocation.kind == "proportional":
        recipients = [pid for pid in order if basis.get(pid, 0) > 0]
        if not recipients:
            return ChargeResult(charge.id, "noBasis")
        return divided(recipients, [basis[pid] for pid in recipients])
    if allocation.kind == "equal":
        chosen = allocation.members if allocation.members is not None else order
        outsider = next((pid for pid in chosen if pid not in participants), None)
        if outsider is not None:
            return ChargeResult(charge.id, "notAParticipant", participant=outsider)
        if not chosen:
            return ChargeResult(charge.id, "noRecipients")
        ordered = [pid for pid in order if pid in chosen]
        return divided(ordered, [1] * len(ordered))
    if allocation.kind == "shares":
        outsider = next((pid for pid, _ in allocation.weights if pid not in participants), None)
        if outsider is not None:
            return ChargeResult(charge.id, "notAParticipant", participant=outsider)
        positive: list[tuple[str, int]] = []
        for pid in order:
            match = next(((p, w) for p, w in allocation.weights if p == pid and w > 0), None)
            if match is not None:
                positive.append(match)
        if not positive:
            return ChargeResult(charge.id, "noRecipients")
        return divided([p for p, _ in positive], [w for _, w in positive])
    if allocation.kind == "exact":
        outsider = next((pid for pid, _ in allocation.amounts if pid not in participants), None)
        if outsider is not None:
            return ChargeResult(charge.id, "notAParticipant", participant=outsider)
        assigned = sum(value for _, value in allocation.amounts)
        if assigned != amount:
            return ChargeResult(charge.id, "exactMismatch", remaining=amount - assigned)
        ordered_exact: list[tuple[str, int]] = []
        for pid in order:
            match = next(((p, v) for p, v in allocation.amounts if p == pid and v != 0), None)
            if match is not None:
                ordered_exact.append(match)
        return ChargeResult(charge.id, "allocated", shares=ordered_exact)
    # payer
    if room.payer_id is None:
        return ChargeResult(charge.id, "payerMissing")
    return ChargeResult(charge.id, "allocated", shares=[(room.payer_id, amount)])


def allocate(room: Room) -> Allocation:
    order = room.participant_ids
    participants = set(order)
    items = [allocate_item(item, room.claims_for(item.id), participants, order) for item in room.receipt.items]
    basis: dict[str, int] = {}
    for result in items:
        for pid, amount in result.shares:
            basis[pid] = basis.get(pid, 0) + amount
    charges = [allocate_charge(charge, basis, room, order) for charge in room.receipt.charges]

    totals: dict[str, ParticipantTotal] = {}
    extra: list[str] = []

    def touch(pid: str) -> ParticipantTotal:
        if pid not in totals:
            totals[pid] = ParticipantTotal(pid)
            if pid not in participants:
                extra.append(pid)
        return totals[pid]

    for pid in order:
        touch(pid)
    for result in items:
        for pid, amount in result.shares:
            total = touch(pid)
            total.items += amount
            total.item_shares.append((result.item_id, amount))
    for charge, charge_result in zip(room.receipt.charges, charges, strict=True):
        for pid, amount in charge_result.shares:
            total = touch(pid)
            if charge.kind == "tax":
                total.tax += amount
            elif charge.kind == "tip":
                total.tip += amount
            elif charge.kind in ("serviceCharge", "fee"):
                total.fees += amount
            elif charge.kind == "discount":
                total.discounts += amount
            else:
                total.adjustments += amount
    ordered = [totals[pid] for pid in order + extra if pid in totals]
    return Allocation(room.receipt.total, items, charges, ordered)


def preview_split(item: Item, split: dict[str, Any]) -> tuple[str | None, list[tuple[str, int]], int | None]:
    """Validate a shared-item split like `ReceiptAllocationEngine.preview`.

    Returns ``(issue, shares, remaining)`` where ``issue`` is ``None`` when the split adds up.
    """
    amount = item.line_total
    kind = split["kind"]
    if kind == "equal":
        members: list[str] = split["members"]
        if not members:
            return "noOne", [], None
        units, _ = divide_signed(amount, [1] * len(members))
        return None, list(zip(members, units, strict=True)), None
    if kind == "shares":
        weights: list[tuple[str, int]] = split["weights"]
        if not any(weight > 0 for _, weight in weights):
            return "noOne", [], None
        positive = [(pid, weight) for pid, weight in weights if weight > 0]
        units, _ = divide_signed(amount, [w for _, w in positive])
        return None, list(zip([p for p, _ in positive], units, strict=True)), None
    if kind == "units":
        # Units may leave some of the quantity for others to claim; they may never exceed it.
        counts: list[tuple[str, int]] = [(pid, count) for pid, count in split["units"] if count > 0]
        if not counts:
            return "noOne", [], None
        if item.quantity is None or item.quantity < 1:
            return "noQuantity", [], None
        claimed = sum(count for _, count in counts)
        if claimed > item.quantity:
            return "tooManyUnits", [], claimed - item.quantity
        unclaimed = item.quantity - claimed
        amounts, _ = divide_signed(amount, [count for _, count in counts] + ([unclaimed] if unclaimed else []))
        return None, list(zip([pid for pid, _ in counts], amounts[: len(counts)], strict=True)), None
    exact: list[tuple[str, int]] = split["amounts"]
    if not exact:
        return "noOne", [], None
    if not all(value == 0 or (value < 0) == (amount < 0) for _, value in exact):
        return "negativeValue", [], None
    remaining = amount - sum(value for _, value in exact)
    if remaining != 0:
        return "doesNotAddUp", [], remaining
    return None, [(pid, value) for pid, value in exact if value != 0], None
