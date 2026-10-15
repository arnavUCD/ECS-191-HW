import Foundation

/// One row in an activity feed, already expressed from the current user's point of view.
nonisolated struct ActivityEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case expense(ExpenseID)
        case settlement(SettlementID)
        /// A non-ledger audit event: edits, deletions, membership, and payment progress.
        case event(AuditEventID)
    }

    /// What this record means for the current user's *personal* balance.
    enum Effect: Hashable, Sendable {
        /// You paid more than your share; others owe you this much.
        case lent(Money)
        /// You owe this much because someone else paid.
        case borrowed(Money)
        /// You were involved and your share equals what you paid.
        case even
        /// You recorded paying someone back.
        case paidBack(to: MemberID, Money)
        /// Someone recorded paying you back.
        case receivedPayment(from: MemberID, Money)
        /// You are not part of this record.
        case notInvolved
        /// An audit event (no balance effect of its own). `involvesYou` drives Home's feed.
        case event(involvesYou: Bool)
    }

    let id: String
    let kind: Kind
    let groupID: GroupID
    let groupName: String
    let date: Date
    let title: String
    let actorID: MemberID
    let total: Money
    let category: ExpenseCategory?
    let effect: Effect
    /// For settlements: how the money moved and who confirmed it.
    var provider: PaymentProviderKind?
    var confirmedBy: MemberID?
    /// For audit events: the human-language description and category.
    var eventDescription: AuditEventDescription?
    var eventCategory: AuditEvent.Category?
    /// Audit sequence for stable ordering when timestamps tie.
    var sequence: Int = 0

    /// Whether this entry should appear in a personal feed (Home's recent activity).
    var involvesCurrentUser: Bool {
        switch effect {
        case .notInvolved: false
        case .event(let involvesYou): involvesYou
        default: true
        }
    }
}

nonisolated struct ActivitySection: Identifiable, Hashable, Sendable {
    let id: Date
    let title: String
    let entries: [ActivityEntry]
}

nonisolated enum ActivityFeedBuilder {
    static func entries(from snapshot: LedgerSnapshot) -> [ActivityEntry] {
        let me = snapshot.currentUserID
        let groupsByID = Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.id, $0) })
        let labels = PersonIdentity.shortLabels(for: Array(snapshot.members.values))
        var result: [ActivityEntry] = []

        for expense in snapshot.expenses {
            guard let group = groupsByID[expense.groupID] else { continue }
            result.append(ActivityEntry(
                id: "expense-\(expense.id)",
                kind: .expense(expense.id),
                groupID: group.id,
                groupName: group.name,
                date: expense.date,
                title: expense.title,
                actorID: expense.payments.first?.memberID ?? expense.createdBy,
                total: expense.total,
                category: expense.category,
                effect: effect(of: expense, for: me)
            ))
        }

        for settlement in snapshot.settlements {
            guard let group = groupsByID[settlement.groupID] else { continue }
            let effect: ActivityEntry.Effect
            if settlement.fromID == me {
                effect = .paidBack(to: settlement.toID, settlement.amount)
            } else if settlement.toID == me {
                effect = .receivedPayment(from: settlement.fromID, settlement.amount)
            } else {
                effect = .notInvolved
            }
            let payer = labels[settlement.fromID] ?? ""
            let payee = labels[settlement.toID] ?? ""
            let title: String
            if settlement.fromID == me {
                title = String(localized: "You paid \(payee)", comment: "Recorded settlement the current user paid")
            } else if settlement.toID == me {
                title = String(localized: "\(payer) paid you", comment: "Recorded settlement the current user received")
            } else {
                title = String(localized: "\(payer) paid \(payee)", comment: "Recorded settlement title: payer paid payee")
            }
            result.append(ActivityEntry(
                id: "settlement-\(settlement.id)",
                kind: .settlement(settlement.id),
                groupID: group.id,
                groupName: group.name,
                date: settlement.date,
                title: title,
                actorID: settlement.fromID,
                total: settlement.amount,
                category: nil,
                effect: effect,
                provider: settlement.provider,
                confirmedBy: settlement.confirmedBy
            ))
        }

        for event in snapshot.events where AuditEventPresenter.isShownInFeed(event) {
            guard let group = groupsByID[event.groupID] else { continue }
            let description = AuditEventPresenter.describe(event, members: snapshot.members, currentUserID: me)
            result.append(ActivityEntry(
                id: "event-\(event.id)",
                kind: .event(event.id),
                groupID: group.id,
                groupName: group.name,
                date: event.date,
                title: description.title,
                actorID: event.actorID,
                total: description.amount ?? .zero(group.currency),
                category: nil,
                effect: .event(involvesYou: involves(event, me)),
                eventDescription: description,
                eventCategory: event.category,
                sequence: event.sequence
            ))
        }

        return result.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
            return lhs.id < rhs.id
        }
    }

    /// Whether an event concerns the given member directly.
    static func involves(_ event: AuditEvent, _ member: MemberID) -> Bool {
        if event.actorID == member { return true }
        switch event.kind {
        case .memberAdded(let id), .memberRemoved(let id), .memberJoined(let id), .memberLeft(let id): return id == member
        case .memberInvited(let seat): return seat == member
        case .ownershipTransferred(let from, let to): return from == member || to == member
        case .paymentStarted(let info), .paymentReported(let info), .paymentConfirmed(let info, _),
             .paymentRejected(let info, _), .paymentDisputed(let info, _), .paymentCancelled(let info, _),
             .paymentHandoffOpened(let info):
            return info.payerID == member || info.recipientID == member
        default: return false
        }
    }

    /// The personal-balance effect of an expense for `member`.
    static func effect(of expense: Expense, for member: MemberID) -> ActivityEntry.Effect {
        guard expense.participantIDs.contains(member) else { return .notInvolved }
        let personal = expense.paid(by: member) - expense.owed(by: member)
        if personal.isPositive { return .lent(personal) }
        if personal.isNegative { return .borrowed(personal.magnitude) }
        return .even
    }

    static func sections(
        _ entries: [ActivityEntry],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [ActivitySection] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            ActivitySection(
                id: day,
                title: sectionTitle(for: day, now: now, calendar: calendar, locale: locale),
                entries: grouped[day] ?? []
            )
        }
    }

    static func sectionTitle(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return String(localized: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide).month(.abbreviated).day()
        if !sameYear { style = style.year() }
        return day.formatted(style)
    }
}
