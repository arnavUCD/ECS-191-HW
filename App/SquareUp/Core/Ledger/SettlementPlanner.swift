import Foundation

/// One recommended payment: `payerID` pays `recipientID` `amount`.
nonisolated struct PlannedPayment: Identifiable, Hashable, Sendable {
    let groupID: GroupID
    let payerID: MemberID
    let recipientID: MemberID
    let amount: Money

    var id: String { obligationKey }
    var obligationKey: String { PaymentAttempt.obligationKey(groupID: groupID, payerID: payerID, recipientID: recipientID) }
}

/// The confirmed ledger and the actionable plan for one group (milestone 2 §9).
///
/// - `confirmedNets`: expenses minus confirmed settlements — the authoritative balance.
/// - `availableNets`: confirmed balances adjusted by payments reported sent (or disputed) and
///   awaiting confirmation. The plan is computed from these, so a pending payment is never
///   suggested a second time.
nonisolated struct SettlementPlan: Equatable, Sendable {
    let groupID: GroupID
    let currency: CurrencyCode
    let isSimplified: Bool
    /// Actionable payments in the chosen mode, ordered deterministically.
    let payments: [PlannedPayment]
    /// Payment count without simplification (pairwise debts), for "2 payments instead of 5".
    let directPaymentCount: Int
    /// Payment count with simplification.
    let simplifiedPaymentCount: Int
    /// Attempts holding money out of the plan while confirmation is outstanding.
    let pending: [PaymentAttempt]
    let confirmedNets: [MemberID: Money]
    let availableNets: [MemberID: Money]

    /// Nothing left to pay and nothing awaiting confirmation.
    var isSettled: Bool { payments.isEmpty && pending.isEmpty }

    func payment(from payerID: MemberID, to recipientID: MemberID) -> PlannedPayment? {
        payments.first { $0.payerID == payerID && $0.recipientID == recipientID }
    }

    func confirmedNet(for member: MemberID) -> Money { confirmedNets[member] ?? .zero(currency) }
    func availableNet(for member: MemberID) -> Money { availableNets[member] ?? .zero(currency) }
}

nonisolated enum SettlementPlanner {
    static func plan(
        for group: ExpenseGroup,
        expenses: [Expense],
        settlements: [Settlement],
        attempts: [PaymentAttempt],
        simplify: Bool? = nil
    ) -> SettlementPlan {
        let groupExpenses = expenses.filter { $0.groupID == group.id && !$0.isDeleted }
        let groupSettlements = settlements.filter { $0.groupID == group.id }
        let pending = attempts
            .filter { $0.groupID == group.id && $0.state.reservesObligation && $0.amount.currency == group.currency }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.createdAt < $1.createdAt }

        let confirmed = BalanceCalculator.ledger(for: group, expenses: groupExpenses, settlements: groupSettlements)
        // Reserve pending payments exactly as if they were settlements, without recording them.
        let reservations = pending.map {
            Settlement(id: SettlementID($0.id.rawValue), groupID: group.id, fromID: $0.payerID, toID: $0.recipientID,
                       amount: $0.amount, date: $0.createdAt, recordedBy: $0.payerID)
        }
        let available = BalanceCalculator.ledger(for: group, expenses: groupExpenses, settlements: groupSettlements + reservations)

        let order = group.memberIDs
        let direct = directTransfers(ledger: available, order: order)
        let nets = Dictionary(uniqueKeysWithValues: order.map { ($0, available.net(for: $0).minorUnits) })
        let simplified = simplifiedTransfers(nets: nets, order: order)
        let useSimplified = simplify ?? group.simplifiesDebts

        func payments(_ transfers: [Transfer]) -> [PlannedPayment] {
            transfers.map {
                PlannedPayment(groupID: group.id, payerID: $0.from, recipientID: $0.to,
                               amount: Money(minorUnits: $0.units, currency: group.currency))
            }
        }

        return SettlementPlan(
            groupID: group.id,
            currency: group.currency,
            isSimplified: useSimplified,
            payments: payments(useSimplified ? simplified : direct),
            directPaymentCount: direct.count,
            simplifiedPaymentCount: simplified.count,
            pending: pending,
            confirmedNets: Dictionary(uniqueKeysWithValues: order.map { ($0, confirmed.net(for: $0)) }),
            availableNets: Dictionary(uniqueKeysWithValues: order.map { ($0, available.net(for: $0)) })
        )
    }

    nonisolated struct Transfer: Equatable, Sendable {
        let from: MemberID
        let to: MemberID
        let units: Int64
    }

    /// Pairwise debts as they stand: one payment per pair with a non-zero net between them.
    static func directTransfers(ledger: GroupLedger, order: [MemberID]) -> [Transfer] {
        var transfers: [Transfer] = []
        for (index, first) in order.enumerated() {
            for second in order[(index + 1)...] {
                let owed = ledger.netOwed(from: first, to: second).minorUnits
                if owed > 0 { transfers.append(Transfer(from: first, to: second, units: owed)) }
                if owed < 0 { transfers.append(Transfer(from: second, to: first, units: -owed)) }
            }
        }
        return transfers
    }

    /// Debt simplification that preserves every member's net position.
    ///
    /// 1. Exact matches first: a debtor and creditor with identical amounts settle in one payment.
    /// 2. Then greedy: the largest debtor pays the largest creditor, repeatedly.
    ///
    /// Ties always break by the group's membership order, so the same ledger always yields the
    /// same plan. Produces at most `n − 1` payments.
    static func simplifiedTransfers(nets: [MemberID: Int64], order: [MemberID]) -> [Transfer] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var debtors = order.compactMap { id in nets[id].flatMap { $0 < 0 ? (id, -$0) : nil } }
        var creditors = order.compactMap { id in nets[id].flatMap { $0 > 0 ? (id, $0) : nil } }
        var transfers: [Transfer] = []

        // Exact matches, in membership order.
        var index = 0
        while index < debtors.count {
            if let match = creditors.firstIndex(where: { $0.1 == debtors[index].1 }) {
                transfers.append(Transfer(from: debtors[index].0, to: creditors[match].0, units: debtors[index].1))
                debtors.remove(at: index)
                creditors.remove(at: match)
            } else {
                index += 1
            }
        }

        // Greedy largest-first.
        func largest(_ list: [(MemberID, Int64)]) -> Int? {
            list.indices.max { lhs, rhs in
                list[lhs].1 == list[rhs].1
                    ? (rank[list[lhs].0] ?? 0) > (rank[list[rhs].0] ?? 0)
                    : list[lhs].1 < list[rhs].1
            }
        }
        while let debtor = largest(debtors), let creditor = largest(creditors) {
            let units = min(debtors[debtor].1, creditors[creditor].1)
            transfers.append(Transfer(from: debtors[debtor].0, to: creditors[creditor].0, units: units))
            debtors[debtor].1 -= units
            creditors[creditor].1 -= units
            if debtors[debtor].1 == 0 { debtors.remove(at: debtor) }
            if let creditorIndex = creditors.firstIndex(where: { $0.1 == 0 }) { creditors.remove(at: creditorIndex) }
        }

        return transfers.sorted { lhs, rhs in
            let lhsPayer = rank[lhs.from] ?? 0, rhsPayer = rank[rhs.from] ?? 0
            if lhsPayer != rhsPayer { return lhsPayer < rhsPayer }
            return (rank[lhs.to] ?? 0) < (rank[rhs.to] ?? 0)
        }
    }
}
