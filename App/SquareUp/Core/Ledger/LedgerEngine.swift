import Foundation

/// Business-rule violations, each specific enough for the UI to explain.
nonisolated enum LedgerRuleViolation: Error, Equatable, Sendable {
    case groupNameRequired
    case textTooLong
    case memberNameRequired
    case invalidHandle
    case memberAlreadyInGroup(MemberID)
    case memberNotFound
    case notAGroupMember
    case cannotRemoveYourself
    case memberHasBalance(MemberID, Money)
    case memberHasOpenPayment(MemberID)
    case currencyLocked
    case expenseNotFound
    case expenseDeleted
    case expenseNotDeleted
    case inactiveParticipant(MemberID)
    /// The change would alter an obligation that has a payment awaiting confirmation.
    case pendingPaymentConflict([PaymentAttemptID])
    case destinationNotFound
    case notDestinationOwner
    case destinationUnavailable
    case cannotPaySelf
    case nonPositiveAmount
    case currencyMismatch
    /// No current obligation from the payer to the recipient in the plan.
    case noObligation
    /// More than the payer currently owes the recipient. Associated value: what is owed now.
    case exceedsObligation(Money)
    case attemptNotFound
}

/// Group fields a person can set.
nonisolated struct GroupDraft: Equatable, Sendable {
    var name: String
    var details: String = ""
    var symbolName: String = "person.3.fill"
    var currency: CurrencyCode = .usd
    /// New people to create and add.
    var newMembers: [MemberDraft] = []
    /// Known people to add.
    var existingMemberIDs: [MemberID] = []
}

nonisolated struct MemberDraft: Equatable, Sendable {
    var displayName: String
    var handle: String = ""
}

/// Every mutation of the ledger.
nonisolated enum LedgerCommand: Sendable {
    case createGroup(GroupDraft)
    case updateGroup(GroupID, GroupDraft)
    case addMember(GroupID, MemberDraft)
    case addExistingMember(GroupID, MemberID)
    case removeMember(GroupID, MemberID)
    case setSimplification(GroupID, Bool)
    case addExpense(Expense)
    case updateExpense(Expense)
    case deleteExpense(ExpenseID)
    case restoreExpense(ExpenseID)
    /// Direct, already-confirmed record (sample data and tests). Payments go through attempts.
    case recordSettlement(Settlement)
    case saveDestination(PaymentDestination)
    case deleteDestination(PaymentDestinationID)
    case startPayment(PaymentRequest)
    case advancePayment(PaymentAttemptID, PaymentAttemptAction)
    /// PROTOTYPE: choose which sample identity uses this device.
    case switchCurrentUser(MemberID)
    /// Milestone 3: receipt drafts and Live Receipt Rooms.
    case receipt(ReceiptRoomCommand)
}

/// A persisted effect of a command. Stores apply these verbatim, in order.
nonisolated enum LedgerChange: Equatable, Sendable {
    case upsertMember(Member)
    case upsertGroup(ExpenseGroup)
    case upsertExpense(Expense)
    case upsertSettlement(Settlement)
    case upsertDestination(PaymentDestination)
    case deleteDestination(PaymentDestinationID)
    case upsertAttempt(PaymentAttempt)
    case appendEvent(AuditEvent)
    case setCurrentUser(MemberID)
    case upsertRoom(ReceiptRoom)
    /// Only never-opened drafts are deleted; opened rooms are kept as cancelled for history.
    case deleteRoom(ReceiptRoomID)
}

nonisolated struct LedgerCommandResult: Equatable, Sendable {
    var changes: [LedgerChange] = []
    var groupID: GroupID?
    var memberIDs: [MemberID] = []
    var attempt: PaymentAttempt?
    var settlement: Settlement?
    var room: ReceiptRoom?
    var expenseID: ExpenseID?

    /// True when the command was a repeat with nothing to change (idempotent no-op).
    var isNoOp: Bool { changes.isEmpty }
}

/// The single implementation of every ledger rule (milestone 2 §14 "identical rules").
///
/// Pure: given a snapshot, an actor, a clock value, and an ID source, it returns the changes to
/// persist — or throws without side effects. `InMemoryLedgerStore` and `SwiftDataLedgerStore`
/// both delegate here, so tests against either exercise the same behavior.
nonisolated enum LedgerEngine {
    static let maximumNameLength = 60
    static let maximumDetailsLength = 140

    static func perform(
        _ command: LedgerCommand,
        on state: LedgerSnapshot,
        actor: MemberID,
        now: Date,
        makeID: () -> UUID = UUID.init
    ) throws(LedgerError) -> LedgerCommandResult {
        do {
            return try performUnchecked(command, on: state, actor: actor, now: now, makeID: makeID)
        } catch let error as LedgerError {
            throw error
        } catch let violation as LedgerRuleViolation {
            throw .rule(violation)
        } catch let transition as PaymentTransitionError {
            throw .invalidTransition(transition)
        } catch let room as ReceiptRoomError {
            throw .receipt(room)
        } catch {
            throw .unavailable
        }
    }

    private static func performUnchecked(
        _ command: LedgerCommand,
        on state: LedgerSnapshot,
        actor: MemberID,
        now: Date,
        makeID: () -> UUID
    ) throws -> LedgerCommandResult {
        var builder = Builder(state: state, actor: actor, now: now)
        switch command {
        case .createGroup(let draft):
            try createGroup(draft, &builder, makeID)
        case .updateGroup(let id, let draft):
            try updateGroup(id, draft, &builder, makeID)
        case .addMember(let groupID, let draft):
            let member = try newMember(draft, makeID)
            builder.result.changes.append(.upsertMember(member))
            try addMember(member.id, to: groupID, &builder, makeID)
        case .addExistingMember(let groupID, let memberID):
            guard state.members[memberID] != nil else { throw LedgerRuleViolation.memberNotFound }
            try addMember(memberID, to: groupID, &builder, makeID)
        case .removeMember(let groupID, let memberID):
            try removeMember(memberID, from: groupID, &builder, makeID)
        case .setSimplification(let groupID, let enabled):
            var group = try requireGroup(groupID, state)
            guard group.simplifiesDebts != enabled else { break }
            group.simplifiesDebts = enabled
            builder.result.changes.append(.upsertGroup(group))
            builder.event(groupID, .simplificationChanged(enabled: enabled), makeID)
        case .addExpense(let expense):
            try addExpense(expense, &builder, makeID)
        case .updateExpense(let expense):
            try updateExpense(expense, &builder, makeID)
        case .deleteExpense(let id):
            try deleteExpense(id, &builder, makeID)
        case .restoreExpense(let id):
            try restoreExpense(id, &builder, makeID)
        case .recordSettlement(let settlement):
            _ = try requireGroup(settlement.groupID, state)
            guard settlement.amount.isPositive else { throw LedgerRuleViolation.nonPositiveAmount }
            builder.result.changes.append(.upsertSettlement(settlement))
            builder.result.settlement = settlement
            builder.event(settlement.groupID, .settlementRecorded(settlement.id, fromID: settlement.fromID,
                                                                  toID: settlement.toID, amount: settlement.amount), makeID)
        case .saveDestination(let destination):
            try saveDestination(destination, &builder)
        case .deleteDestination(let id):
            try deleteDestination(id, &builder)
        case .startPayment(let request):
            try startPayment(request, &builder, makeID)
        case .advancePayment(let id, let action):
            try advancePayment(id, action, &builder, makeID)
        case .switchCurrentUser(let memberID):
            guard state.members[memberID] != nil else { throw LedgerRuleViolation.memberNotFound }
            if memberID != state.currentUserID { builder.result.changes.append(.setCurrentUser(memberID)) }
        case .receipt(let roomCommand):
            try performReceipt(roomCommand, &builder, makeID)
        }
        return builder.result
    }

    /// Applies changes to a snapshot. Used by the in-memory store and by tests; the SwiftData
    /// store applies the same changes to records.
    static func apply(_ changes: [LedgerChange], to state: LedgerSnapshot) -> LedgerSnapshot {
        var members = state.members
        var groups = state.groups
        var expenses = state.allExpenses
        var settlements = state.settlements
        var destinations = state.paymentDestinations
        var attempts = state.paymentAttempts
        var events = state.events
        var currentUserID = state.currentUserID
        var rooms = state.receiptRooms

        func upsert<T: Identifiable>(_ value: T, into list: inout [T]) {
            if let index = list.firstIndex(where: { $0.id == value.id }) { list[index] = value } else { list.append(value) }
        }

        for change in changes {
            switch change {
            case .upsertMember(let member): members[member.id] = member
            case .upsertGroup(let group): upsert(group, into: &groups)
            case .upsertExpense(let expense): upsert(expense, into: &expenses)
            case .upsertSettlement(let settlement): upsert(settlement, into: &settlements)
            case .upsertDestination(let destination): upsert(destination, into: &destinations)
            case .deleteDestination(let id): destinations.removeAll { $0.id == id }
            case .upsertAttempt(let attempt): upsert(attempt, into: &attempts)
            case .appendEvent(let event): if !events.contains(where: { $0.id == event.id }) { events.append(event) }
            case .setCurrentUser(let id): currentUserID = id
            case .upsertRoom(let room): upsert(room, into: &rooms)
            case .deleteRoom(let id): rooms.removeAll { $0.id == id }
            }
        }
        return LedgerSnapshot(
            currentUserID: currentUserID, members: Array(members.values), groups: groups, expenses: expenses,
            settlements: settlements, paymentDestinations: destinations, paymentAttempts: attempts, events: events,
            defaultCurrency: state.defaultCurrency, receiptRooms: rooms
        )
    }

    // MARK: - Builder

    nonisolated struct Builder {
        let state: LedgerSnapshot
        let actor: MemberID
        let now: Date
        var result = LedgerCommandResult()
        private var sequence: Int

        init(state: LedgerSnapshot, actor: MemberID, now: Date) {
            self.state = state
            self.actor = actor
            self.now = now
            sequence = state.nextEventSequence
        }

        mutating func event(_ groupID: GroupID, _ kind: AuditEvent.Kind, _ makeID: () -> UUID) {
            result.changes.append(.appendEvent(AuditEvent(
                id: AuditEventID(makeID()), groupID: groupID, actorID: actor, date: now, sequence: sequence, kind: kind
            )))
            sequence += 1
        }
    }

    // MARK: - Groups

    private static func validatedName(_ text: String, required: LedgerRuleViolation) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw required }
        guard name.count <= maximumNameLength else { throw LedgerRuleViolation.textTooLong }
        return name
    }

    private static func validatedDetails(_ text: String) throws -> String? {
        let details = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard details.count <= maximumDetailsLength else { throw LedgerRuleViolation.textTooLong }
        return details.isEmpty ? nil : details
    }

    static func validatedHandle(_ text: String) throws -> String? {
        var handle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        guard !handle.isEmpty else { return nil }
        guard handle.wholeMatch(of: /[A-Za-z0-9._\-]{1,30}/) != nil else { throw LedgerRuleViolation.invalidHandle }
        return handle.lowercased()
    }

    private static func newMember(_ draft: MemberDraft, _ makeID: () -> UUID) throws -> Member {
        Member(
            id: MemberID(makeID()),
            displayName: try validatedName(draft.displayName, required: .memberNameRequired),
            handle: try validatedHandle(draft.handle)
        )
    }

    static func requireGroup(_ id: GroupID, _ state: LedgerSnapshot) throws -> ExpenseGroup {
        guard let group = state.group(id) else { throw LedgerError.groupNotFound }
        return group
    }

    private static func createGroup(_ draft: GroupDraft, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let name = try validatedName(draft.name, required: .groupNameRequired)
        let details = try validatedDetails(draft.details)
        var memberships = [Membership(memberID: builder.actor)]
        for id in draft.existingMemberIDs where id != builder.actor && !memberships.contains(where: { $0.memberID == id }) {
            guard builder.state.members[id] != nil else { throw LedgerRuleViolation.memberNotFound }
            memberships.append(Membership(memberID: id))
        }
        for memberDraft in draft.newMembers {
            let member = try newMember(memberDraft, makeID)
            builder.result.changes.append(.upsertMember(member))
            builder.result.memberIDs.append(member.id)
            memberships.append(Membership(memberID: member.id))
        }
        let group = ExpenseGroup(
            id: GroupID(makeID()), name: name, currency: draft.currency,
            symbolName: draft.symbolName, memberships: memberships, createdAt: builder.now, details: details
        )
        builder.result.changes.append(.upsertGroup(group))
        builder.result.groupID = group.id
        builder.event(group.id, .groupCreated(name: name), makeID)
    }

    /// Any financial record pins the currency (milestone 2 §6).
    static func hasFinancialRecords(_ groupID: GroupID, in state: LedgerSnapshot) -> Bool {
        state.allExpenses.contains { $0.groupID == groupID }
            || state.settlements.contains { $0.groupID == groupID }
            || state.paymentAttempts.contains { $0.groupID == groupID }
    }

    private static func updateGroup(_ id: GroupID, _ draft: GroupDraft, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        var group = try requireGroup(id, builder.state)
        let name = try validatedName(draft.name, required: .groupNameRequired)
        let details = try validatedDetails(draft.details)
        var fields: [GroupField] = []
        if name != group.name { fields.append(.name) }
        if details != group.details { fields.append(.details) }
        if draft.symbolName != group.symbolName { fields.append(.symbol) }
        if draft.currency != group.currency {
            guard !hasFinancialRecords(id, in: builder.state) else { throw LedgerRuleViolation.currencyLocked }
            fields.append(.currency)
        }
        guard !fields.isEmpty else { return }
        group.name = name
        group.details = details
        group.symbolName = draft.symbolName
        group.currency = draft.currency
        builder.result.changes.append(.upsertGroup(group))
        builder.result.groupID = id
        builder.event(id, .groupEdited(fields: fields), makeID)
    }

    private static func addMember(_ memberID: MemberID, to groupID: GroupID, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        var group = try requireGroup(groupID, builder.state)
        if let index = group.memberships.firstIndex(where: { $0.memberID == memberID }) {
            guard !group.memberships[index].isActive else { throw LedgerRuleViolation.memberAlreadyInGroup(memberID) }
            group.memberships[index].removedAt = nil
        } else {
            group.memberships.append(Membership(memberID: memberID))
        }
        builder.result.changes.append(.upsertGroup(group))
        builder.result.memberIDs.append(memberID)
        builder.event(groupID, .memberAdded(memberID), makeID)
    }

    private static func removeMember(_ memberID: MemberID, from groupID: GroupID, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        var group = try requireGroup(groupID, builder.state)
        guard memberID != builder.actor else { throw LedgerRuleViolation.cannotRemoveYourself }
        guard let index = group.memberships.firstIndex(where: { $0.memberID == memberID && $0.isActive }) else {
            throw LedgerRuleViolation.notAGroupMember
        }
        let state = builder.state
        let ledger = BalanceCalculator.ledger(for: group, expenses: state.expenses(in: groupID), settlements: state.settlements(in: groupID))
        let net = ledger.net(for: memberID)
        guard net.isZero else { throw LedgerRuleViolation.memberHasBalance(memberID, net) }
        let hasOpenAttempt = state.attempts(in: groupID).contains {
            !$0.state.isTerminal && ($0.payerID == memberID || $0.recipientID == memberID)
        }
        guard !hasOpenAttempt else { throw LedgerRuleViolation.memberHasOpenPayment(memberID) }
        group.memberships[index].removedAt = builder.now
        builder.result.changes.append(.upsertGroup(group))
        builder.event(groupID, .memberRemoved(memberID), makeID)
    }

    // MARK: - Expenses

    private static func validate(_ expense: Expense, previous: Expense?, in group: ExpenseGroup) throws {
        do {
            try ExpenseValidator.validate(expense, in: group)
        } catch let error as ExpenseValidationError {
            throw LedgerError.invalidExpense(error)
        }
        let grandfathered = Set(previous?.participantIDs ?? [])
        for id in expense.participantIDs where !group.isActiveMember(id) && !grandfathered.contains(id) {
            throw LedgerRuleViolation.inactiveParticipant(id)
        }
    }

    /// Blocks a change that would alter the balance of anyone with a payment awaiting
    /// confirmation (milestone 2 §18): the pending payment must be resolved first.
    private static func checkPendingConflicts(groupID: GroupID, replacing old: Expense?, with new: Expense?, _ state: LedgerSnapshot) throws {
        guard let group = state.group(groupID) else { return }
        let reserving = state.attempts(in: groupID).filter(\.state.reservesObligation)
        guard !reserving.isEmpty else { return }
        let others = state.expenses(in: groupID).filter { $0.id != old?.id && $0.id != new?.id }
        let settlements = state.settlements(in: groupID)
        let before = BalanceCalculator.ledger(for: group, expenses: others + [old].compactMap { $0 }.filter { !$0.isDeleted },
                                              settlements: settlements)
        let after = BalanceCalculator.ledger(for: group, expenses: others + [new].compactMap { $0 }.filter { !$0.isDeleted },
                                             settlements: settlements)
        let conflicts = reserving.filter { attempt in
            [attempt.payerID, attempt.recipientID].contains { before.net(for: $0) != after.net(for: $0) }
        }
        guard conflicts.isEmpty else { throw LedgerRuleViolation.pendingPaymentConflict(conflicts.map(\.id)) }
    }

    /// Shared by manual entry and receipt finalization (milestone 3 §9.3 "existing ledger command path").
    static func addExpense(_ expense: Expense, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let group = try requireGroup(expense.groupID, builder.state)
        try validate(expense, previous: nil, in: group)
        try checkPendingConflicts(groupID: group.id, replacing: nil, with: expense, builder.state)
        var stored = expense
        stored.revision = 1
        stored.deletedAt = nil
        builder.result.changes.append(.upsertExpense(stored))
        builder.event(group.id, .expenseCreated(expense.id, title: expense.title, total: expense.total), makeID)
    }

    private static func updateExpense(_ expense: Expense, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        guard let old = builder.state.expense(expense.id) else { throw LedgerRuleViolation.expenseNotFound }
        guard !old.isDeleted else { throw LedgerRuleViolation.expenseDeleted }
        let group = try requireGroup(old.groupID, builder.state)
        var updated = expense
        // Identity and provenance are not editable.
        updated = Expense(
            id: old.id, groupID: old.groupID, title: expense.title, merchant: expense.merchant, date: expense.date,
            total: expense.total, category: expense.category, splitMethod: expense.splitMethod,
            payments: expense.payments, allocations: expense.allocations,
            note: expense.note, createdBy: old.createdBy, createdAt: old.createdAt, revision: old.revision,
            updatedAt: old.updatedAt, updatedBy: old.updatedBy
        )
        let fields = ExpenseChangeSummary.changedFields(from: old, to: updated)
        guard !fields.isEmpty else { return }
        try validate(updated, previous: old, in: group)
        try checkPendingConflicts(groupID: group.id, replacing: old, with: updated, builder.state)
        updated.revision = old.revision + 1
        updated.updatedAt = builder.now
        updated.updatedBy = builder.actor
        builder.result.changes.append(.upsertExpense(updated))
        builder.event(group.id, .expenseEdited(updated.id, title: updated.title, fields: fields,
                                               previous: old.revisionSnapshot, revision: updated.revision), makeID)
    }

    private static func deleteExpense(_ id: ExpenseID, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        guard var expense = builder.state.expense(id) else { throw LedgerRuleViolation.expenseNotFound }
        guard !expense.isDeleted else { throw LedgerRuleViolation.expenseDeleted }
        try checkPendingConflicts(groupID: expense.groupID, replacing: expense, with: nil, builder.state)
        expense.deletedAt = builder.now
        expense.deletedBy = builder.actor
        builder.result.changes.append(.upsertExpense(expense))
        builder.event(expense.groupID, .expenseDeleted(id, snapshot: expense.revisionSnapshot), makeID)
    }

    private static func restoreExpense(_ id: ExpenseID, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        guard var expense = builder.state.expense(id) else { throw LedgerRuleViolation.expenseNotFound }
        guard expense.isDeleted else { throw LedgerRuleViolation.expenseNotDeleted }
        expense.deletedAt = nil
        expense.deletedBy = nil
        try checkPendingConflicts(groupID: expense.groupID, replacing: nil, with: expense, builder.state)
        builder.result.changes.append(.upsertExpense(expense))
        builder.event(expense.groupID, .expenseRestored(id, title: expense.title), makeID)
    }
}
