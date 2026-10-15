import Foundation

/// What an edit changes, for the pre-save summary and the audit log (milestone 2 §8).
nonisolated struct ExpenseChangeSummary: Equatable, Sendable {
    nonisolated struct MemberImpact: Equatable, Sendable {
        let memberID: MemberID
        /// Personal effect before and after (positive = lent, negative = owes).
        let before: Money
        let after: Money
        var delta: Money { after - before }
    }

    let fields: [ExpenseField]
    /// Members whose personal effect from this expense changes, largest change first.
    let impacts: [MemberImpact]

    var hasChanges: Bool { !fields.isEmpty }

    static func make(from old: Expense, to new: Expense) -> ExpenseChangeSummary {
        let members = Set(old.participantIDs + new.participantIDs)
        let impacts = members.compactMap { id -> MemberImpact? in
            let before = effect(of: old, for: id)
            let after = effect(of: new, for: id)
            guard before.currency == after.currency, before != after else { return nil }
            return MemberImpact(memberID: id, before: before, after: after)
        }
        .sorted { lhs, rhs in
            lhs.delta.magnitude == rhs.delta.magnitude
                ? lhs.memberID.rawValue.uuidString < rhs.memberID.rawValue.uuidString
                : lhs.delta.magnitude > rhs.delta.magnitude
        }
        return ExpenseChangeSummary(fields: changedFields(from: old, to: new), impacts: impacts)
    }

    static func changedFields(from old: Expense, to new: Expense) -> [ExpenseField] {
        var fields: [ExpenseField] = []
        if old.title != new.title || old.merchant != new.merchant { fields.append(.title) }
        if old.total != new.total { fields.append(.amount) }
        if old.date != new.date { fields.append(.date) }
        if old.category != new.category { fields.append(.category) }
        if Set(old.payments) != Set(new.payments) { fields.append(.payers) }
        let oldParticipants = Set(old.allocations.map(\.memberID))
        let newParticipants = Set(new.allocations.map(\.memberID))
        if oldParticipants != newParticipants { fields.append(.participants) }
        if old.splitMethod != new.splitMethod || (oldParticipants == newParticipants && Set(old.allocations) != Set(new.allocations)) {
            fields.append(.split)
        }
        return fields
    }

    /// Personal effect of one expense: paid minus owed.
    static func effect(of expense: Expense, for member: MemberID) -> Money {
        expense.paid(by: member) - expense.owed(by: member)
    }
}
