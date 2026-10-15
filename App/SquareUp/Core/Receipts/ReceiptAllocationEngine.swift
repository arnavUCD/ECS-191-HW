import Foundation

/// How one item is currently divided.
nonisolated struct ItemAllocation: Hashable, Sendable {
    nonisolated enum Status: Hashable, Sendable {
        /// A zero-value line kept as a note.
        case note
        case unclaimed
        case allocated
        /// Exact claims leave this much unassigned.
        case partial(remaining: Money)
        case invalid(InvalidReason)
    }

    nonisolated enum InvalidReason: Hashable, Sendable {
        /// Exact amounts mixed with equal or share claims.
        case mixedModes
        /// Exact claims exceed the item by this much.
        case exceeds(Money)
        case zeroWeights
        /// A claimant is no longer a room participant.
        case notAParticipant(MemberID)
        /// An exact amount has the opposite sign of the line (e.g. positive on a refund).
        case wrongSign
        /// Units were claimed on a line without a printed quantity.
        case noQuantity
        /// Unit claims add up to more than the printed quantity, by this many.
        case unitsExceed(Int)
    }

    let itemID: ReceiptItemID
    let status: Status
    let shares: [Share]
    let rounding: [RoundingNote]
    let claimants: [MemberID]

    var isShared: Bool { claimants.count > 1 }
    var isResolved: Bool { status == .allocated || status == .note }
}

/// How one additional charge is currently divided.
nonisolated struct ChargeAllocationResult: Hashable, Sendable {
    nonisolated enum Status: Hashable, Sendable {
        case allocated
        /// Proportional allocation needs someone with a positive item subtotal.
        case noBasis
        /// Exact amounts differ from the charge by `remaining` (charge − assigned).
        case exactMismatch(remaining: Money)
        case noRecipients
        case payerMissing
        case notAParticipant(MemberID)
    }

    let chargeID: ReceiptChargeID
    let status: Status
    let shares: [Share]
    let rounding: [RoundingNote]
    var isAllocated: Bool { status == .allocated }
}

/// The exact allocation of a receipt among people, with proof of equality (milestone 3 §7.4, §8).
nonisolated struct ReceiptAllocation: Equatable, Sendable {
    let currency: CurrencyCode
    let receiptTotal: Money?
    let items: [ItemAllocation]
    let charges: [ChargeAllocationResult]
    /// Room participants first (room order), then anyone else holding a share (e.g. the payer).
    let participants: [ParticipantTotal]

    var rounding: [RoundingNote] { items.flatMap(\.rounding) + charges.flatMap(\.rounding) }
    /// Sum of every assigned share.
    var allocatedTotal: Money { participants.map(\.total).sum(in: currency) }
    var remaining: Money? { receiptTotal.map { $0 - allocatedTotal } }
    var unresolvedItems: [ItemAllocation] { items.filter { !$0.isResolved } }
    var unallocatedCharges: [ChargeAllocationResult] { charges.filter { !$0.isAllocated } }
    /// Every item and charge allocated and the participant totals equal the receipt total exactly.
    var isComplete: Bool {
        unresolvedItems.isEmpty && unallocatedCharges.isEmpty && remaining?.isZero == true
    }

    func item(_ id: ReceiptItemID) -> ItemAllocation? { items.first { $0.itemID == id } }
    func charge(_ id: ReceiptChargeID) -> ChargeAllocationResult? { charges.first { $0.chargeID == id } }
    func participant(_ id: MemberID) -> ParticipantTotal {
        participants.first { $0.memberID == id } ?? .zero(id, currency)
    }
}

/// Deterministic itemized allocation (milestone 3 §11 `ReceiptAllocationCalculating`).
///
/// All division uses `SplitCalculator.allocate` — integer minor units, largest remainder, ties by
/// room participant order — so every result sums exactly to its source and is reproducible.
/// Negative lines (refunds, discounts) are divided by magnitude and negated, so the cent that
/// rounding moves always goes to the same person whatever the sign.
nonisolated enum ReceiptAllocationEngine {
    static func allocate(_ room: ReceiptRoom) -> ReceiptAllocation {
        let receipt = room.receipt
        let currency = receipt.currencyCode
        let order = room.participantIDs
        let participantSet = Set(order)

        let items = receipt.items.map { item in
            allocate(item, claims: room.claims(for: item.id), participants: participantSet, order: order)
        }
        var basis: [MemberID: Int64] = [:]
        // Proportional charges follow item claims, including partially assigned items.
        for share in items.flatMap(\.shares) { basis[share.memberID, default: 0] += share.amount.minorUnits }
        let charges = receipt.charges.map { charge in
            allocate(charge, basis: basis, room: room, order: order)
        }

        var totals: [MemberID: ParticipantTotal] = [:]
        var extraOrder: [MemberID] = []
        func touch(_ id: MemberID) {
            if totals[id] == nil {
                totals[id] = .zero(id, currency)
                if !participantSet.contains(id) { extraOrder.append(id) }
            }
        }
        order.forEach(touch)
        for allocation in items {
            for share in allocation.shares {
                touch(share.memberID)
                totals[share.memberID]?.items += share.amount
                totals[share.memberID]?.itemShares.append(.init(itemID: allocation.itemID, amount: share.amount))
            }
        }
        for (charge, allocation) in zip(receipt.charges, charges) {
            for share in allocation.shares {
                touch(share.memberID)
                switch charge.kind {
                case .tax: totals[share.memberID]?.tax += share.amount
                case .tip: totals[share.memberID]?.tip += share.amount
                case .serviceCharge, .fee: totals[share.memberID]?.fees += share.amount
                case .discount: totals[share.memberID]?.discounts += share.amount
                case .adjustment: totals[share.memberID]?.adjustments += share.amount
                }
            }
        }
        let participants = (order + extraOrder).compactMap { totals[$0] }
        return ReceiptAllocation(currency: currency, receiptTotal: receipt.total.value, items: items, charges: charges, participants: participants)
    }

    // MARK: - Items

    static func allocate(_ item: ReceiptLineItem, claims: [ReceiptClaim], participants: Set<MemberID>, order: [MemberID]) -> ItemAllocation {
        let sorted = claims.sorted { (order.firstIndex(of: $0.memberID) ?? .max) < (order.firstIndex(of: $1.memberID) ?? .max) }
        let claimants = sorted.map(\.memberID)
        func result(_ status: ItemAllocation.Status, _ shares: [Share] = [], _ rounding: [RoundingNote] = []) -> ItemAllocation {
            ItemAllocation(itemID: item.id, status: status, shares: shares, rounding: rounding, claimants: claimants)
        }
        if item.isNote { return result(.note) }
        guard !sorted.isEmpty else { return result(.unclaimed) }
        if let outsider = claimants.first(where: { !participants.contains($0) }) { return result(.invalid(.notAParticipant(outsider))) }

        let amount = item.amount
        let exacts = sorted.compactMap { claim -> Share? in
            if case .exact(let money) = claim.mode { return Share(claim.memberID, money) }
            return nil
        }
        if !exacts.isEmpty {
            guard exacts.count == sorted.count else { return result(.invalid(.mixedModes)) }
            guard exacts.allSatisfy({ $0.amount.isZero || $0.amount.isNegative == amount.isNegative }) else { return result(.invalid(.wrongSign)) }
            let assigned = exacts.map(\.amount).sum(in: amount.currency)
            if assigned == amount { return result(.allocated, exacts) }
            let remaining = amount - assigned
            if remaining.isNegative != amount.isNegative { return result(.invalid(.exceeds(remaining.magnitude))) }
            return result(.partial(remaining: remaining), exacts)
        }
        if sorted.contains(where: \.mode.isUnits) {
            return allocateUnits(item, sorted, result: result)
        }
        let weights = sorted.map { claim -> (MemberID, Decimal) in
            switch claim.mode {
            case .shares(let count): (claim.memberID, Decimal(max(count, 0)))
            case .full, .equalShare, .exact, .units: (claim.memberID, 1)
            }
        }
        guard weights.contains(where: { $0.1 > 0 }) else { return result(.invalid(.zeroWeights)) }
        let (shares, rounding) = divide(amount, weights: weights, source: .item(item.id))
        return result(.allocated, shares, rounding)
    }

    /// Unit claims ("2 of the 3"): each person pays for their units of the line, divided by largest
    /// remainder over the printed quantity. Units nobody claimed stay unassigned (`partial`).
    private static func allocateUnits(
        _ item: ReceiptLineItem, _ claims: [ReceiptClaim], result: (ItemAllocation.Status, [Share], [RoundingNote]) -> ItemAllocation
    ) -> ItemAllocation {
        let counts = claims.compactMap { claim -> (MemberID, Int)? in
            if case .units(let count) = claim.mode { return (claim.memberID, max(count, 0)) }
            return nil
        }
        guard counts.count == claims.count else { return result(.invalid(.mixedModes), [], []) }
        guard let quantity = item.quantity, quantity >= 1 else { return result(.invalid(.noQuantity), [], []) }
        let claimed = counts.map(\.1).reduce(0, +)
        if claimed > quantity { return result(.invalid(.unitsExceed(claimed - quantity)), [], []) }
        guard claimed > 0 else { return result(.invalid(.zeroWeights), [], []) }
        let (shares, rounding, remaining) = divideUnits(item, counts: counts, quantity: quantity)
        if let remaining { return result(.partial(remaining: remaining), shares, []) }
        return result(.allocated, shares, rounding)
    }

    /// The amounts for unit counts over the printed quantity. Unclaimed units form one more bucket
    /// in the same largest-remainder division, so the claimed shares don't depend on who claims later
    /// beyond a cent of rounding; that bucket is returned as what's still unassigned.
    static func divideUnits(_ item: ReceiptLineItem, counts: [(MemberID, Int)], quantity: Int) -> ([Share], [RoundingNote], Money?) {
        let amount = item.amount
        let unclaimed = quantity - counts.map(\.1).reduce(0, +)
        // A placeholder member stands for the unclaimed units; it never appears in the result.
        let rest = MemberID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        var weights = counts.map { ($0.0, Decimal($0.1)) }
        if unclaimed > 0 { weights.append((rest, Decimal(unclaimed))) }
        let (all, rounding) = divide(amount, weights: weights, source: .item(item.id))
        let shares = all.filter { $0.memberID != rest }
        let remaining = unclaimed > 0 ? all.first { $0.memberID == rest }?.amount : nil
        return (shares, rounding.filter { $0.memberID != rest }, remaining)
    }

    /// The shared-item editor's live preview (§8.7): the division, or why it doesn't add up.
    static func preview(_ split: ItemSplit, of item: ReceiptLineItem) -> Result<[Share], ItemSplitIssue> {
        let amount = item.amount
        switch split {
        case .units(let counts):
            let positive = counts.filter { $0.units > 0 }
            guard !positive.isEmpty else { return .failure(.noOne) }
            guard counts.allSatisfy({ $0.units >= 0 }) else { return .failure(.negativeValue) }
            guard let quantity = item.quantity, quantity >= 1 else { return .failure(.noQuantity) }
            let claimed = positive.map(\.units).reduce(0, +)
            if claimed > quantity { return .failure(.tooManyUnits(claimed - quantity)) }
            return .success(divideUnits(item, counts: positive.map { ($0.memberID, $0.units) }, quantity: quantity).0)
        case .equal(let ids):
            guard !ids.isEmpty else { return .failure(.noOne) }
            return .success(divide(amount, weights: ids.map { ($0, 1) }, source: .item(item.id)).0)
        case .shares(let weights):
            guard weights.contains(where: { $0.weight > 0 }) else { return .failure(.noOne) }
            guard weights.allSatisfy({ $0.weight >= 0 }) else { return .failure(.negativeValue) }
            let positive = weights.filter { $0.weight > 0 }
            return .success(divide(amount, weights: positive.map { ($0.memberID, Decimal($0.weight)) }, source: .item(item.id)).0)
        case .exact(let shares):
            guard !shares.isEmpty else { return .failure(.noOne) }
            guard shares.allSatisfy({ $0.amount.isZero || $0.amount.isNegative == amount.isNegative }) else { return .failure(.negativeValue) }
            let remaining = amount - shares.map(\.amount).sum(in: amount.currency)
            return remaining.isZero ? .success(shares.filter { !$0.amount.isZero }) : .failure(.doesNotAddUp(remaining: remaining))
        }
    }

    /// Claims that reproduce an explicit split.
    static func claims(for split: ItemSplit, itemID: ReceiptItemID, at date: Date, revision: Int, existing: [ReceiptClaim]) -> [ReceiptClaim] {
        func claim(_ memberID: MemberID, _ mode: ClaimMode) -> ReceiptClaim {
            let created = existing.first { $0.memberID == memberID }?.createdAt ?? date
            return ReceiptClaim(itemID: itemID, memberID: memberID, mode: mode, createdAt: created, updatedAt: date, revision: revision)
        }
        switch split {
        case .equal(let ids):
            return ids.map { claim($0, ids.count == 1 ? .full : .equalShare) }
        case .shares(let weights):
            return weights.filter { $0.weight > 0 }.map { claim($0.memberID, .shares($0.weight)) }
        case .exact(let shares):
            return shares.filter { !$0.amount.isZero }.map { claim($0.memberID, .exact($0.amount)) }
        case .units(let counts):
            return counts.filter { $0.units > 0 }.map { claim($0.memberID, .units($0.units)) }
        }
    }

    // MARK: - Charges

    static func allocate(_ charge: ReceiptCharge, basis: [MemberID: Int64], room: ReceiptRoom, order: [MemberID]) -> ChargeAllocationResult {
        let amount = charge.value
        func result(_ status: ChargeAllocationResult.Status, _ shares: [Share] = [], _ rounding: [RoundingNote] = []) -> ChargeAllocationResult {
            ChargeAllocationResult(chargeID: charge.id, status: status, shares: shares, rounding: rounding)
        }
        let participants = Set(order)
        switch charge.allocation {
        case .proportional:
            let weights = order.compactMap { id -> (MemberID, Decimal)? in
                guard let units = basis[id], units > 0 else { return nil }
                return (id, Decimal(units))
            }
            guard !weights.isEmpty else { return result(.noBasis) }
            let (shares, rounding) = divide(amount, weights: weights, source: .charge(charge.id))
            return result(.allocated, shares, rounding)
        case .equal(let ids):
            let recipients = ids ?? order
            if let outsider = recipients.first(where: { !participants.contains($0) }) { return result(.notAParticipant(outsider)) }
            guard !recipients.isEmpty else { return result(.noRecipients) }
            let ordered = order.filter(recipients.contains)
            let (shares, rounding) = divide(amount, weights: ordered.map { ($0, 1) }, source: .charge(charge.id))
            return result(.allocated, shares, rounding)
        case .shares(let weights):
            if let outsider = weights.first(where: { !participants.contains($0.memberID) }) { return result(.notAParticipant(outsider.memberID)) }
            let positive = order.compactMap { id in weights.first { $0.memberID == id && $0.weight > 0 } }
            guard !positive.isEmpty else { return result(.noRecipients) }
            let (shares, rounding) = divide(amount, weights: positive.map { ($0.memberID, Decimal($0.weight)) }, source: .charge(charge.id))
            return result(.allocated, shares, rounding)
        case .exact(let exact):
            if let outsider = exact.first(where: { !participants.contains($0.memberID) }) { return result(.notAParticipant(outsider.memberID)) }
            let assigned = exact.map(\.amount).sum(in: amount.currency)
            guard assigned == amount else { return result(.exactMismatch(remaining: amount - assigned)) }
            let ordered = order.compactMap { id in exact.first { $0.memberID == id && !$0.amount.isZero } }
            return result(.allocated, ordered)
        case .payer:
            guard let payerID = room.payerID else { return result(.payerMissing) }
            return result(.allocated, [Share(payerID, amount)])
        }
    }

    // MARK: - Division

    /// Largest-remainder division of a signed amount: divides the magnitude and restores the sign.
    static func divide(_ amount: Money, weights: [(MemberID, Decimal)], source: RoundingNote.Source) -> ([Share], [RoundingNote]) {
        let split = SplitCalculator.allocate(amount.magnitude, weights: weights)
        let sign: Decimal = amount.isNegative ? -1 : 1
        let shares = split.shares.map { Share($0.memberID, Money($0.amount.amount * sign, amount.currency)) }
        let rounding = weights.compactMap { id, _ in
            split.roundingAdjustments[id].map { RoundingNote(source: source, memberID: id, amount: Money($0.amount * sign, amount.currency)) }
        }
        return (shares, rounding)
    }
}

/// Why a shared-item split can't be saved yet.
nonisolated enum ItemSplitIssue: Error, Hashable, Sendable {
    case noOne
    case negativeValue
    /// item − assigned: positive means more to assign, negative means over-assigned.
    case doesNotAddUp(remaining: Money)
    /// The line has no printed quantity to divide by.
    case noQuantity
    /// More units than the line's printed quantity, by this many.
    case tooManyUnits(Int)
}
