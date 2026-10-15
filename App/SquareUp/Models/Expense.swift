import Foundation

/// The financial content of one expense revision, kept in the audit log after an edit or
/// deletion so history can always be explained.
nonisolated struct ExpenseRevision: Hashable, Sendable, Codable {
    let revision: Int
    let title: String
    let total: Money
    let date: Date
    let category: ExpenseCategory
    let splitMethod: SplitMethod
    let payments: [Share]
    let allocations: [Share]
}

/// An amount attributed to one person: what they paid, or what they owe.
nonisolated struct Share: Hashable, Sendable, Codable {
    let memberID: MemberID
    let amount: Money

    init(_ memberID: MemberID, _ amount: Money) {
        self.memberID = memberID
        self.amount = amount
    }
}

nonisolated enum SplitMethod: String, Codable, Sendable, CaseIterable {
    case equal
    case exact
    case percentage
    case shares
    /// Receipt items claimed per person (Live Receipt Room). Created by finalizing a room.
    case itemized

    /// Methods that can be entered manually in the current build.
    static let manualMethods: [SplitMethod] = [.equal, .exact, .percentage, .shares]
}

nonisolated enum ExpenseCategory: String, Codable, Sendable, CaseIterable {
    case food
    case groceries
    case housing
    case utilities
    case transport
    case travel
    case entertainment
    case supplies
    case other
}

/// How a split was entered (milestone 7). Sent with a shared-group expense so the server can
/// recompute the split itself; never stored on this device (an edit may reopen a split as its
/// exact amounts).
nonisolated enum SplitInput: Hashable, Sendable {
    /// Equal among these people, in this order (the order decides who absorbs leftover cents).
    case equal([MemberID])
    case shares([MemberWeight])
    case percentage([MemberPercent])
}

/// One person's percentage of a split ("33.34").
nonisolated struct MemberPercent: Hashable, Sendable {
    let memberID: MemberID
    let percent: Decimal

    init(_ memberID: MemberID, _ percent: Decimal) {
        self.memberID = memberID
        self.percent = percent
    }
}

/// The complete financial record. Balances are always derived from these, never stored.
///
/// Invariants (enforced by `ExpenseValidator`):
/// - `payments` sum to `total`.
/// - `allocations` sum to `total`.
/// - Every amount shares `total.currency`.
nonisolated struct Expense: Identifiable, Hashable, Sendable {
    let id: ExpenseID
    let groupID: GroupID
    var title: String
    var merchant: String?
    var date: Date
    var total: Money
    var category: ExpenseCategory
    var splitMethod: SplitMethod
    var payments: [Share]
    var allocations: [Share]
    var note: String?
    var createdBy: MemberID
    var createdAt: Date
    /// Starts at 1 and increments on every saved edit. Older revisions live in the audit log.
    var revision: Int
    var updatedAt: Date?
    var updatedBy: MemberID?
    /// Tombstone. A deleted expense keeps its record (for history) but never affects balances.
    var deletedAt: Date?
    var deletedBy: MemberID?
    /// Transient: how the split was entered, for server recomputation (see `SplitInput`).
    var splitInput: SplitInput?

    init(
        id: ExpenseID = ExpenseID(),
        groupID: GroupID,
        title: String,
        merchant: String? = nil,
        date: Date,
        total: Money,
        category: ExpenseCategory,
        splitMethod: SplitMethod,
        payments: [Share],
        allocations: [Share],
        note: String? = nil,
        createdBy: MemberID,
        createdAt: Date? = nil,
        revision: Int = 1,
        updatedAt: Date? = nil,
        updatedBy: MemberID? = nil,
        deletedAt: Date? = nil,
        deletedBy: MemberID? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.merchant = merchant
        self.date = date
        self.total = total
        self.category = category
        self.splitMethod = splitMethod
        self.payments = payments
        self.allocations = allocations
        self.note = note
        self.createdBy = createdBy
        self.createdAt = createdAt ?? date
        self.revision = revision
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
    }

    var isDeleted: Bool { deletedAt != nil }

    /// The financially meaningful fields, used for revision history and change summaries.
    var revisionSnapshot: ExpenseRevision {
        ExpenseRevision(
            revision: revision, title: title, total: total, date: date, category: category,
            splitMethod: splitMethod, payments: payments, allocations: allocations
        )
    }

    var currency: CurrencyCode { total.currency }

    func paid(by memberID: MemberID) -> Money {
        payments.filter { $0.memberID == memberID }.map(\.amount).sum(in: currency)
    }

    func owed(by memberID: MemberID) -> Money {
        allocations.filter { $0.memberID == memberID }.map(\.amount).sum(in: currency)
    }

    var participantIDs: [MemberID] {
        var seen = Set<MemberID>()
        return (payments + allocations).map(\.memberID).filter { seen.insert($0).inserted }
    }
}
