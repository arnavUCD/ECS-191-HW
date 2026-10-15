import Foundation

nonisolated enum ExpenseValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case nonPositiveTotal
    case noPayer
    case noParticipants
    case currencyMismatch
    case negativeShare
    case paymentsDoNotReconcile(remaining: Money)
    case allocationsDoNotReconcile(remaining: Money)
    case participantNotInGroup(MemberID)
}

/// Enforces the invariants that make every balance reconcile.
nonisolated enum ExpenseValidator {
    static func validate(_ expense: Expense, in group: ExpenseGroup) throws {
        let currency = expense.currency
        guard !expense.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExpenseValidationError.emptyTitle
        }
        guard expense.total.isPositive else { throw ExpenseValidationError.nonPositiveTotal }
        guard !expense.payments.isEmpty else { throw ExpenseValidationError.noPayer }

        let amounts = expense.payments.map(\.amount) + expense.allocations.map(\.amount)
        guard amounts.allSatisfy({ $0.currency == currency }) else {
            throw ExpenseValidationError.currencyMismatch
        }
        guard amounts.allSatisfy({ !$0.isNegative }) else { throw ExpenseValidationError.negativeShare }

        let groupMembers = Set(group.memberIDs)
        for id in expense.participantIDs where !groupMembers.contains(id) {
            throw ExpenseValidationError.participantNotInGroup(id)
        }

        let paid = expense.payments.map(\.amount).sum(in: currency)
        guard paid == expense.total else {
            throw ExpenseValidationError.paymentsDoNotReconcile(remaining: expense.total - paid)
        }

        if expense.total.isPositive {
            guard !expense.allocations.isEmpty else { throw ExpenseValidationError.noParticipants }
        }
        let allocated = expense.allocations.map(\.amount).sum(in: currency)
        guard allocated == expense.total else {
            throw ExpenseValidationError.allocationsDoNotReconcile(remaining: expense.total - allocated)
        }
    }
}
