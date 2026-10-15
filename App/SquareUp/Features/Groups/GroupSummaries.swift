import Foundation

/// A group as listed in Groups.
nonisolated struct GroupListItem: Identifiable, Equatable, Sendable {
    var id: GroupID { group.id }
    let group: ExpenseGroup
    let members: [Member]
    /// The current user's personal net in this group (positive = owed to them).
    let yourNet: Money
    let isSettled: Bool
    let currentUserID: MemberID
}

nonisolated struct MemberBalance: Identifiable, Equatable, Sendable {
    var id: MemberID { member.id }
    let member: Member
    /// Positive: the member is owed overall in this group.
    let net: Money
}

/// What the current user and one other person owe each other in a group.
nonisolated struct Relationship: Identifiable, Equatable, Sendable {
    var id: MemberID { member.id }
    let member: Member
    /// Positive: they owe you. Negative: you owe them.
    let amount: Money
}

nonisolated struct GroupDetailSummary: Equatable, Sendable {
    let group: ExpenseGroup
    let currentUserID: MemberID
    let members: [Member]
    let memberLookup: [MemberID: Member]
    let yourNet: Money
    let relationships: [Relationship]
    let memberBalances: [MemberBalance]
    let isSettled: Bool
    /// Active expenses, newest first.
    let recordedExpenses: [ActivityEntry]
    let activity: [ActivityEntry]
    /// Soft-deleted expenses, newest deletion first. Shown distinctly; never in balances.
    let deletedExpenses: [Expense]
    /// Confirmed vs available balances and the optimized plan.
    let plan: SettlementPlan
    /// Payments started by or to the current user that are not finished.
    let openAttempts: [PaymentAttempt]
    /// Active expenses, for balance explanations.
    let activeExpenses: [Expense]
    /// Milestone 3: receipt drafts and rooms in progress for this group.
    var unfinishedRooms: [ReceiptRoom] = []
    /// Everyone sending or receiving a payment that isn't confirmed, cancelled, or rejected yet.
    var peopleWithPaymentsInProgress: Set<MemberID> = []

    var activeMembers: [Member] { group.activeMemberIDs.compactMap { memberLookup[$0] } }

    /// What the group has spent on expenses that still count (deleted ones excluded).
    var totalSpent: Money {
        activeExpenses.reduce(Money.zero(group.currency)) { $0 + $1.total }
    }

    /// How each active expense affected a member, newest first (balance explanation).
    func contributions(for memberID: MemberID, expenses: [Expense]) -> [(expense: Expense, effect: Money)] {
        expenses
            .filter { $0.participantIDs.contains(memberID) }
            .map { ($0, ExpenseChangeSummary.effect(of: $0, for: memberID)) }
            .filter { !$0.1.isZero }
            .sorted { $0.0.date > $1.0.date }
    }
}

nonisolated enum GroupSummaryBuilder {
    static func listItems(from snapshot: LedgerSnapshot) -> [GroupListItem] {
        snapshot.groupsForCurrentUser.map { group in
            let ledger = BalanceCalculator.ledger(
                for: group,
                expenses: snapshot.expenses(in: group.id),
                settlements: snapshot.settlements(in: group.id)
            )
            return GroupListItem(
                group: group,
                members: snapshot.members(of: group),
                yourNet: ledger.net(for: snapshot.currentUserID),
                isSettled: ledger.isSettled,
                currentUserID: snapshot.currentUserID
            )
        }
    }

    static func detail(for groupID: GroupID, in snapshot: LedgerSnapshot) throws -> GroupDetailSummary {
        let state = snapshot
        guard let group = snapshot.group(groupID) else { throw LedgerError.groupNotFound }
        let me = snapshot.currentUserID
        let expenses = snapshot.expenses(in: groupID)
        let ledger = BalanceCalculator.ledger(for: group, expenses: expenses, settlements: snapshot.settlements(in: groupID))
        let members = snapshot.members(of: group)

        let relationships = ledger.relationships(for: me).compactMap { pair -> Relationship? in
            guard let member = snapshot.members[pair.other] else { return nil }
            return Relationship(member: member, amount: pair.amount)
        }

        let balances = members
            .map { MemberBalance(member: $0, net: ledger.net(for: $0.id)) }
            .sorted { lhs, rhs in
                if lhs.member.id == me { return true }
                if rhs.member.id == me { return false }
                return lhs.member.displayName.localizedStandardCompare(rhs.member.displayName) == .orderedAscending
            }

        let entries = ActivityFeedBuilder.entries(from: snapshot).filter { $0.groupID == groupID }
        let expenseEntries = entries.filter { if case .expense = $0.kind { true } else { false } }

        return GroupDetailSummary(
            group: group,
            currentUserID: me,
            members: members,
            memberLookup: snapshot.members,
            yourNet: ledger.net(for: me),
            relationships: relationships,
            memberBalances: balances,
            isSettled: ledger.isSettled,
            recordedExpenses: expenseEntries,
            activity: entries,
            deletedExpenses: state.deletedExpenses.filter { $0.groupID == groupID }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) },
            plan: SettlementPlanner.plan(for: group, expenses: expenses, settlements: state.settlements(in: groupID),
                                         attempts: state.attempts(in: groupID)),
            openAttempts: state.attempts(in: groupID)
                .filter { !$0.state.isTerminal && ($0.payerID == me || $0.recipientID == me) }
                .sorted { $0.createdAt > $1.createdAt },
            activeExpenses: expenses,
            unfinishedRooms: snapshot.unfinishedRooms(in: groupID),
            peopleWithPaymentsInProgress: Set(state.attempts(in: groupID).filter { !$0.state.isTerminal }.flatMap { [$0.payerID, $0.recipientID] })
        )
    }
}
