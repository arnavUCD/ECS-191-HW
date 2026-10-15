import Foundation

/// Everything Expense Detail shows, derived from one snapshot.
nonisolated struct ExpenseDetailSummary: Equatable, Sendable {
    let expense: Expense
    let group: ExpenseGroup
    let members: [MemberID: Member]
    let currentUserID: MemberID
    /// Oldest first: created, edits (with the previous revision), deletion, restoration.
    let history: [AuditEvent]
    /// Payments awaiting confirmation whose balances this expense touches.
    let blockingAttempts: [PaymentAttempt]
    /// Milestone 3: the Live Receipt Room this itemized expense was finalized from.
    let receiptRoom: ReceiptRoom?

    static func make(expenseID: ExpenseID, from snapshot: LedgerSnapshot) throws -> ExpenseDetailSummary {
        guard let expense = snapshot.expense(expenseID) else { throw LedgerError.rule(.expenseNotFound) }
        guard let group = snapshot.group(expense.groupID) else { throw LedgerError.groupNotFound }
        let involved = Set(expense.participantIDs)
        return ExpenseDetailSummary(
            expense: expense,
            group: group,
            members: snapshot.members,
            currentUserID: snapshot.currentUserID,
            history: snapshot.events(in: group.id).filter { references($0, expenseID) },
            blockingAttempts: snapshot.attempts(in: group.id).filter {
                $0.state.reservesObligation && (involved.contains($0.payerID) || involved.contains($0.recipientID))
            },
            receiptRoom: snapshot.room(forExpense: expenseID)
        )
    }

    static func references(_ event: AuditEvent, _ id: ExpenseID) -> Bool {
        switch event.kind {
        case .expenseCreated(let expenseID, _, _), .expenseEdited(let expenseID, _, _, _, _),
             .expenseDeleted(let expenseID, _), .expenseRestored(let expenseID, _), .receiptRoomFinalized(_, let expenseID, _),
             .receiptRoomAdopted(_, let expenseID, _):
            expenseID == id
        default:
            false
        }
    }

    /// What deleting would change, per person: the reverse of each person's current effect.
    var deletionImpacts: [(memberID: MemberID, effect: Money)] {
        expense.participantIDs
            .map { ($0, ExpenseChangeSummary.effect(of: expense, for: $0)) }
            .filter { !$0.1.isZero }
    }

    /// The current user's effect from this expense (positive = lent).
    var yourEffect: Money { ExpenseChangeSummary.effect(of: expense, for: currentUserID) }
}

/// Who may change an expense. On this iPhone, anyone; in a shared group, the person who added it
/// edits or deletes it, and the owner may also delete or restore it to resolve an exceptional case
/// (recorded in the history as the owner's action). The server enforces the same rules.
nonisolated struct ExpensePermissions: Equatable, Sendable {
    var canEdit: Bool
    var canDelete: Bool
    /// Deleting or restoring it would be the owner acting on someone else's expense.
    var actsAsOwner: Bool

    static let local = ExpensePermissions(canEdit: true, canDelete: true, actsAsOwner: false)

    static func shared(_ expense: Expense, viewer: MemberID, isOwner: Bool, isArchived: Bool) -> ExpensePermissions {
        guard !isArchived else { return ExpensePermissions(canEdit: false, canDelete: false, actsAsOwner: false) }
        let isCreator = expense.createdBy == viewer
        return ExpensePermissions(canEdit: isCreator, canDelete: isCreator || isOwner, actsAsOwner: !isCreator && isOwner)
    }
}
