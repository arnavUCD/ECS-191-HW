import Foundation
import OSLog

/// Who owes whom inside one group, derived entirely from expenses and recorded settlements.
///
/// Balances between people only: every amount comes from an expense's payments and allocations
/// or from a recorded settlement.
nonisolated struct GroupLedger: Sendable, Equatable {
    struct Pair: Hashable, Sendable {
        let debtor: MemberID
        let creditor: MemberID
    }

    let groupID: GroupID
    let currency: CurrencyCode
    /// Gross minor units each debtor owes each creditor before netting.
    private let gross: [Pair: Int64]
    let memberIDs: [MemberID]

    init(groupID: GroupID, currency: CurrencyCode, memberIDs: [MemberID], gross: [Pair: Int64]) {
        self.groupID = groupID
        self.currency = currency
        self.memberIDs = memberIDs
        self.gross = gross
    }

    /// Positive when `debtor` owes `creditor` after netting both directions.
    func netOwed(from debtor: MemberID, to creditor: MemberID) -> Money {
        let forward = gross[Pair(debtor: debtor, creditor: creditor)] ?? 0
        let backward = gross[Pair(debtor: creditor, creditor: debtor)] ?? 0
        return Money(minorUnits: forward - backward, currency: currency)
    }

    /// Positive: the member is owed money overall. Negative: the member owes money overall.
    func net(for member: MemberID) -> Money {
        var units: Int64 = 0
        for (pair, value) in gross {
            if pair.creditor == member { units += value }
            if pair.debtor == member { units -= value }
        }
        return Money(minorUnits: units, currency: currency)
    }

    /// Non-zero balances between `member` and each other person.
    /// Positive amount: the other person owes `member`. Negative: `member` owes them.
    func relationships(for member: MemberID) -> [(other: MemberID, amount: Money)] {
        memberIDs
            .filter { $0 != member }
            .map { other in (other, netOwed(from: other, to: member)) }
            .filter { !$0.1.isZero }
            .sorted { $0.1.magnitude > $1.1.magnitude }
    }

    var isSettled: Bool {
        memberIDs.allSatisfy { net(for: $0).isZero }
    }
}

nonisolated enum BalanceCalculator {
    /// Builds the pairwise ledger for a group.
    ///
    /// Each allocation is owed to the payer(s) in proportion to what they paid, using the same
    /// largest-remainder rule as splits so pairwise amounts always reconcile to the cent.
    /// Settlements reduce what the payer owed the recipient.
    static func ledger(for group: ExpenseGroup, expenses: [Expense], settlements: [Settlement]) -> GroupLedger {
        var gross: [GroupLedger.Pair: Int64] = [:]
        let currency = group.currency

        for expense in expenses where expense.groupID == group.id {
            guard expense.currency == currency else {
                Log.persistence.error("Skipped expense in a non-group currency")
                continue
            }
            let payerWeights = expense.payments.map { Decimal($0.amount.minorUnits) }
            for allocation in expense.allocations {
                let portions = SplitCalculator.distribute(
                    minorUnits: allocation.amount.minorUnits,
                    weights: payerWeights
                )
                for (payment, units) in zip(expense.payments, portions)
                    where payment.memberID != allocation.memberID && units != 0 {
                    gross[.init(debtor: allocation.memberID, creditor: payment.memberID), default: 0] += units
                }
            }
        }

        for settlement in settlements where settlement.groupID == group.id {
            guard settlement.amount.currency == currency else { continue }
            // Paying someone you owe is equivalent to them now owing you that amount back.
            gross[.init(debtor: settlement.toID, creditor: settlement.fromID), default: 0] += settlement.amount.minorUnits
        }

        return GroupLedger(groupID: group.id, currency: currency, memberIDs: group.memberIDs, gross: gross)
    }
}
