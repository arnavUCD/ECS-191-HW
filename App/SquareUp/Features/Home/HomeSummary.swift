import Foundation

/// The current user's personal position across groups in one currency.
nonisolated struct NetPosition: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case owed
        case owe
        case square
    }

    /// Sum of groups where others owe you.
    let owedToYou: Money
    /// Sum of groups where you owe others (as a positive magnitude).
    let youOwe: Money

    var net: Money { owedToYou - youOwe }

    var direction: Direction {
        if net.isPositive { return .owed }
        if net.isNegative { return .owe }
        return .square
    }

    /// The share of everything open that is owed to you (0…1), for display only; `nil` when
    /// nothing is open.
    var owedShare: Double? {
        let total = owedToYou.amount + youOwe.amount
        guard total > 0 else { return nil }
        return NSDecimalNumber(decimal: owedToYou.amount / total).doubleValue
    }
}

/// Why a group appears in "Needs attention".
nonisolated struct GroupAttention: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// You owe people in this group. `counterparties` are ordered by amount.
        case youOwe(Money, counterparties: [MemberID])
        /// People in this group owe you.
        case owedToYou(Money, counterparties: [MemberID])
    }

    var id: GroupID { group.id }
    let group: ExpenseGroup
    let reason: Reason
    let memberIDs: [MemberID]
    /// Your personal net in the group (positive = owed to you).
    let yourNet: Money
}

nonisolated struct HomeSummary: Equatable, Sendable {
    let currentUser: Member
    let currency: CurrencyCode
    let position: NetPosition
    let activeGroupCount: Int
    /// Groups whose currency differs from `currency`; excluded from `position` (no conversion).
    let otherCurrencyGroupCount: Int
    let attention: [GroupAttention]
    let recent: [ActivityEntry]
    let members: [MemberID: Member]
    /// Payments others reported sending you, awaiting your confirmation (or disputed).
    var paymentsToConfirm: [PaymentAttempt] = []
    /// Your handoffs that opened another app but were never reported (return prompt; survives relaunch).
    var unfinishedPayments: [PaymentAttempt] = []
    /// Payments you reported, awaiting the recipient.
    var awaitingOthers: [PaymentAttempt] = []
    var groupNames: [GroupID: String] = [:]
    /// Milestone 3: receipt drafts and rooms you host or are in, still in progress.
    var unfinishedReceipts: [ReceiptRoom] = []

    var hasGroups: Bool { activeGroupCount > 0 }
}

/// Deterministic derivation of everything Home shows. Views never compute these numbers.
nonisolated enum HomeSummaryBuilder {
    static let attentionLimit = 4
    static let recentLimit = 5

    static func build(from snapshot: LedgerSnapshot) -> HomeSummary? {
        guard let me = snapshot.currentUser else { return nil }
        let currency = snapshot.defaultCurrency
        let myGroups = snapshot.groupsForCurrentUser

        var owedToYou = Money.zero(currency)
        var youOwe = Money.zero(currency)
        var otherCurrencyGroups = 0
        var attention: [(priority: Int, magnitude: Money, item: GroupAttention)] = []

        for group in myGroups {
            let expenses = snapshot.expenses(in: group.id)
            let ledger = BalanceCalculator.ledger(
                for: group,
                expenses: expenses,
                settlements: snapshot.settlements(in: group.id)
            )
            let net = ledger.net(for: me.id)

            if group.currency == currency {
                if net.isPositive { owedToYou += net }
                if net.isNegative { youOwe += net.magnitude }
            } else {
                otherCurrencyGroups += 1
            }

            let (reason, priority) = attentionReason(ledger: ledger, me: me.id, net: net)
            if let reason {
                attention.append((priority, net.magnitude, GroupAttention(
                    group: group,
                    reason: reason,
                    memberIDs: group.memberIDs,
                    yourNet: net
                )))
            }
        }

        let sortedAttention = attention
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                if lhs.magnitude.currency == rhs.magnitude.currency, lhs.magnitude != rhs.magnitude {
                    return lhs.magnitude > rhs.magnitude
                }
                return lhs.item.group.name.localizedStandardCompare(rhs.item.group.name) == .orderedAscending
            }
            .prefix(attentionLimit)
            .map(\.item)

        let myGroupIDs = Set(myGroups.map(\.id))
        let recent = ActivityFeedBuilder.entries(from: snapshot)
            .filter { myGroupIDs.contains($0.groupID) && $0.involvesCurrentUser }
            .prefix(recentLimit)

        let myGroupSet = Set(myGroups.map(\.id))
        let attempts = snapshot.paymentAttempts.filter { myGroupSet.contains($0.groupID) }
            .sorted { $0.createdAt > $1.createdAt }

        return HomeSummary(
            currentUser: me,
            currency: currency,
            position: NetPosition(owedToYou: owedToYou, youOwe: youOwe),
            activeGroupCount: myGroups.count,
            otherCurrencyGroupCount: otherCurrencyGroups,
            attention: Array(sortedAttention),
            recent: Array(recent),
            members: snapshot.members,
            paymentsToConfirm: attempts.filter { $0.recipientID == me.id && $0.state.reservesObligation },
            unfinishedPayments: attempts.filter { $0.payerID == me.id && $0.state == .handoffOpened },
            awaitingOthers: attempts.filter { $0.payerID == me.id && $0.state.reservesObligation },
            groupNames: Dictionary(uniqueKeysWithValues: myGroups.map { ($0.id, $0.name) }),
            unfinishedReceipts: snapshot.unfinishedRooms.filter { $0.hostID == me.id || $0.participantIDs.contains(me.id) }
        )
    }

    /// Milestone 7: Home across this iPhone's groups and every shared group. Each shared group's
    /// summary is built from its own workspace (where "you" is this account's seat), then combined.
    /// Amounts in another currency are never added together; those groups are counted instead.
    static func merging(_ base: HomeSummary, with others: [HomeSummary]) -> HomeSummary {
        var owedToYou = base.position.owedToYou
        var youOwe = base.position.youOwe
        var otherCurrency = base.otherCurrencyGroupCount
        var attention = base.attention
        var recent = base.recent
        var members = base.members
        var summary = base
        for other in others where other.hasGroups {
            if other.currency == base.currency {
                owedToYou += other.position.owedToYou
                youOwe += other.position.youOwe
            } else {
                otherCurrency += other.activeGroupCount
            }
            attention += other.attention
            recent += other.recent
            members.merge(other.members) { first, _ in first }
            summary.paymentsToConfirm += other.paymentsToConfirm
            summary.unfinishedPayments += other.unfinishedPayments
            summary.awaitingOthers += other.awaitingOthers
            summary.groupNames.merge(other.groupNames) { first, _ in first }
            summary.unfinishedReceipts += other.unfinishedReceipts
        }
        func priority(_ item: GroupAttention) -> Int { if case .youOwe = item.reason { 0 } else { 1 } }
        let sortedAttention = attention.sorted { lhs, rhs in
            if priority(lhs) != priority(rhs) { return priority(lhs) < priority(rhs) }
            if lhs.yourNet.currency == rhs.yourNet.currency, lhs.yourNet.magnitude != rhs.yourNet.magnitude {
                return lhs.yourNet.magnitude > rhs.yourNet.magnitude
            }
            return lhs.group.name.localizedStandardCompare(rhs.group.name) == .orderedAscending
        }
        let byDate = { (lhs: PaymentAttempt, rhs: PaymentAttempt) in lhs.createdAt > rhs.createdAt }
        return HomeSummary(
            currentUser: base.currentUser, currency: base.currency, position: NetPosition(owedToYou: owedToYou, youOwe: youOwe),
            activeGroupCount: base.activeGroupCount + others.map(\.activeGroupCount).reduce(0, +), otherCurrencyGroupCount: otherCurrency,
            attention: Array(sortedAttention.prefix(attentionLimit)),
            recent: Array(recent.sorted { $0.date > $1.date }.prefix(recentLimit)), members: members,
            paymentsToConfirm: summary.paymentsToConfirm.sorted(by: byDate), unfinishedPayments: summary.unfinishedPayments.sorted(by: byDate),
            awaitingOthers: summary.awaitingOthers.sorted(by: byDate), groupNames: summary.groupNames,
            unfinishedReceipts: summary.unfinishedReceipts.sorted { $0.createdAt > $1.createdAt }
        )
    }

    /// The group the Settle up action should open: somewhere you owe first, then somewhere
    /// you're owed. Nil when every group is square.
    static func settleUpTarget(in summary: HomeSummary) -> GroupID? {
        let owe = summary.attention.first { if case .youOwe = $0.reason { true } else { false } }
        let owed = summary.attention.first { if case .owedToYou = $0.reason { true } else { false } }
        return (owe ?? owed)?.group.id
    }

    /// Why a group needs the current user, and how urgently (lower is more urgent): money you owe
    /// comes before money owed to you.
    static func attentionReason(ledger: GroupLedger, me: MemberID, net: Money) -> (GroupAttention.Reason?, Int) {
        let relationships = ledger.relationships(for: me)
        if net.isNegative {
            return (.youOwe(net.magnitude, counterparties: relationships.filter { $0.amount.isNegative }.map(\.other)), 0)
        }
        if net.isPositive {
            return (.owedToYou(net, counterparties: relationships.filter { $0.amount.isPositive }.map(\.other)), 1)
        }
        return (nil, .max)
    }
}
