import Foundation

/// An immutable, consistent view of the whole local ledger.
///
/// Repositories produce snapshots; calculators and `LedgerEngine` consume them; views never mutate
/// them. `expenses` contains only active (non-deleted) expenses, so every balance calculation
/// ignores tombstones automatically; `allExpenses` keeps them for history.
nonisolated struct LedgerSnapshot: Sendable, Equatable {
    let currentUserID: MemberID
    let members: [MemberID: Member]
    let groups: [ExpenseGroup]
    /// Every expense record, including soft-deleted ones.
    let allExpenses: [Expense]
    /// Confirmed payments only.
    let settlements: [Settlement]
    let paymentDestinations: [PaymentDestination]
    let paymentAttempts: [PaymentAttempt]
    /// Append-only audit log, in sequence order.
    let events: [AuditEvent]
    /// The person's preferred currency for summary figures.
    let defaultCurrency: CurrencyCode
    /// Milestone 3: receipt drafts and Live Receipt Rooms (every state, including finalized).
    let receiptRooms: [ReceiptRoom]

    init(
        currentUserID: MemberID,
        members: [Member],
        groups: [ExpenseGroup],
        expenses: [Expense],
        settlements: [Settlement],
        paymentDestinations: [PaymentDestination] = [],
        paymentAttempts: [PaymentAttempt] = [],
        events: [AuditEvent] = [],
        defaultCurrency: CurrencyCode = .usd,
        receiptRooms: [ReceiptRoom] = []
    ) {
        self.currentUserID = currentUserID
        self.members = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.groups = groups
        allExpenses = expenses
        self.settlements = settlements
        self.paymentDestinations = paymentDestinations
        self.paymentAttempts = paymentAttempts
        self.events = events.sorted { $0.sequence < $1.sequence }
        self.defaultCurrency = defaultCurrency
        self.receiptRooms = receiptRooms.sorted { $0.createdAt == $1.createdAt ? $0.id.description < $1.id.description : $0.createdAt < $1.createdAt }
    }

    /// Active expenses — the only ones that affect balances.
    var expenses: [Expense] { allExpenses.filter { !$0.isDeleted } }
    var deletedExpenses: [Expense] { allExpenses.filter(\.isDeleted) }

    var currentUser: Member? { members[currentUserID] }

    func group(_ id: GroupID) -> ExpenseGroup? {
        groups.first { $0.id == id }
    }

    /// Everyone who has ever belonged to the group, in membership order.
    func members(of group: ExpenseGroup) -> [Member] {
        group.memberIDs.compactMap { members[$0] }
    }

    /// Members who can join new expenses and payments.
    func activeMembers(of group: ExpenseGroup) -> [Member] {
        group.activeMemberIDs.compactMap { members[$0] }
    }

    func expenses(in groupID: GroupID) -> [Expense] {
        expenses.filter { $0.groupID == groupID }
    }

    func expense(_ id: ExpenseID) -> Expense? {
        allExpenses.first { $0.id == id }
    }

    func settlements(in groupID: GroupID) -> [Settlement] {
        settlements.filter { $0.groupID == groupID }
    }

    func attempts(in groupID: GroupID) -> [PaymentAttempt] {
        paymentAttempts.filter { $0.groupID == groupID }
    }

    func attempt(_ id: PaymentAttemptID) -> PaymentAttempt? {
        paymentAttempts.first { $0.id == id }
    }

    func events(in groupID: GroupID) -> [AuditEvent] {
        events.filter { $0.groupID == groupID }
    }

    /// A member's destinations, preferred first, then provider order, then creation order.
    func destinations(of memberID: MemberID) -> [PaymentDestination] {
        paymentDestinations
            .filter { $0.ownerID == memberID }
            .sorted { lhs, rhs in
                if lhs.isPreferred != rhs.isPreferred { return lhs.isPreferred }
                let lhsOrder = PaymentProviderKind.allCases.firstIndex(of: lhs.provider) ?? 0
                let rhsOrder = PaymentProviderKind.allCases.firstIndex(of: rhs.provider) ?? 0
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func destination(_ id: PaymentDestinationID) -> PaymentDestination? {
        paymentDestinations.first { $0.id == id }
    }

    /// Groups the current user belongs to, most recently active first.
    var groupsForCurrentUser: [ExpenseGroup] {
        let lastActivity = Dictionary(
            grouping: expenses.map { ($0.groupID, $0.date) } + settlements.map { ($0.groupID, $0.date) }
                + events.map { ($0.groupID, $0.date) },
            by: \.0
        ).mapValues { $0.map(\.1).max() ?? .distantPast }
        return groups
            .filter { $0.isActiveMember(currentUserID) }
            .sorted { lhs, rhs in
                let lhsDate = lastActivity[lhs.id] ?? lhs.createdAt
                let rhsDate = lastActivity[rhs.id] ?? rhs.createdAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: Receipt rooms

    func room(_ id: ReceiptRoomID) -> ReceiptRoom? {
        receiptRooms.first { $0.id == id }
    }

    /// The room an itemized expense was finalized from.
    func room(forExpense id: ExpenseID) -> ReceiptRoom? {
        receiptRooms.first { $0.finalExpenseID == id }
    }

    /// Drafts and rooms still in progress (not finalized or cancelled), newest first.
    var unfinishedRooms: [ReceiptRoom] {
        receiptRooms.filter { !$0.state.isTerminal }.sorted { $0.createdAt > $1.createdAt }
    }

    func unfinishedRooms(in groupID: GroupID) -> [ReceiptRoom] {
        unfinishedRooms.filter { $0.groupID == groupID }
    }

    /// The next audit sequence number.
    var nextEventSequence: Int { (events.last?.sequence ?? 0) + 1 }
}
