import Foundation

nonisolated enum LedgerError: Error, Equatable, Sendable {
    case groupNotFound
    case currentUserMissing
    case invalidExpense(ExpenseValidationError)
    /// Storage failed. The associated text is a type name only — never user content.
    case storage(String)
    case unavailable
    /// A business rule prevented the change; nothing was saved.
    case rule(LedgerRuleViolation)
    case invalidDestination(DestinationValidationError)
    case invalidTransition(PaymentTransitionError)
    /// Milestone 3: a receipt or room rule prevented the change; nothing was saved.
    case receipt(ReceiptRoomError)
    /// Milestone 4: a shared-room request didn't go through.
    case remote(RemoteIssue)
}

/// Why a shared-room request didn't go through, in terms people can act on.
nonisolated enum RemoteIssue: Equatable, Sendable {
    /// This build has no server configured.
    case notConfigured
    /// Couldn't reach the server. Nothing is confirmed until it does.
    case offline
    /// Someone else changed the room first; the latest is now showing.
    case conflict
    /// The invitation or this person's access ended (expired, revoked, or removed by the host).
    case accessEnded
    /// The host must say who each guest is in the group before saving the expense.
    case guestsNeedMatching
    case signInFailed(AccountSession.Failure)
    /// The server refused; its message is safe to show.
    case refused(String)
    /// Something unexpected; try again.
    case unavailable
    // Milestone 7: shared groups.
    /// A high-consequence change (joining, removing someone, confirming a payment) needs a live
    /// answer; nothing was changed and nothing is queued.
    case connectionRequired
    /// This account is no longer in the shared group (removed, left, or the group is gone).
    case removedFromGroup
    /// A group invitation can't be used, and why.
    case invitation(GroupInvitationIssue)
    /// Shared groups need a verified email address; nothing was changed.
    case emailNotVerified
}

/// Why a group invitation can't be used (milestone 7 §4.3).
nonisolated enum GroupInvitationIssue: Equatable, Sendable {
    case invalid
    case expired
    case revoked
    /// Someone else already used this single-use invitation.
    case used
    case alreadyMember
    case archived
    /// The place it was for has been taken or removed.
    case seatUnavailable
    /// Shared groups need an account with an email (an anonymous one works on this iPhone only).
    case accountRequired
    /// Choose the name people will see first.
    case profileRequired
    /// The group already has its limit of people (25).
    case groupFull
}

/// Reads a consistent snapshot of everything balances are derived from.
///
/// `revision` increases after every successful mutation; screens use it as a `.task(id:)`
/// key so they refresh without polling.
protocol LedgerReading: AnyObject {
    var revision: Int { get }
    func snapshot() async throws -> LedgerSnapshot
}

/// Executes a `LedgerCommand` through `LedgerEngine` and persists the result atomically.
///
/// `actor` defaults to the device's current user. The local prototype passes an explicit actor
/// only for clearly labelled sample-identity actions (e.g. responding as the recipient).
protocol LedgerCommandPerforming: AnyObject {
    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult
}

/// Groups and membership (overview: `GroupRepository`).
protocol GroupRepository: LedgerCommandPerforming, LedgerReading {}

extension GroupRepository {
    func group(_ id: GroupID) async throws -> ExpenseGroup {
        guard let group = try await snapshot().group(id) else { throw LedgerError.groupNotFound }
        return group
    }

    @discardableResult
    func createGroup(_ draft: GroupDraft) async throws -> GroupID {
        guard let id = try await perform(.createGroup(draft), as: nil).groupID else { throw LedgerError.unavailable }
        return id
    }

    func updateGroup(_ id: GroupID, with draft: GroupDraft) async throws {
        try await perform(.updateGroup(id, draft), as: nil)
    }

    @discardableResult
    func addMember(_ draft: MemberDraft, to groupID: GroupID) async throws -> MemberID {
        guard let id = try await perform(.addMember(groupID, draft), as: nil).memberIDs.first else { throw LedgerError.unavailable }
        return id
    }

    func addExistingMember(_ memberID: MemberID, to groupID: GroupID) async throws {
        try await perform(.addExistingMember(groupID, memberID), as: nil)
    }

    func removeMember(_ memberID: MemberID, from groupID: GroupID) async throws {
        try await perform(.removeMember(groupID, memberID), as: nil)
    }

    func setSimplification(_ enabled: Bool, for groupID: GroupID) async throws {
        try await perform(.setSimplification(groupID, enabled), as: nil)
    }
}

/// Expense records (overview: `ExpenseRepository`). Every write re-validates all invariants.
protocol ExpenseRepository: LedgerCommandPerforming {}

extension ExpenseRepository {
    func add(_ expense: Expense) async throws {
        try await perform(.addExpense(expense), as: nil)
    }

    /// Saves a new revision. The previous revision is kept in the audit log.
    func update(_ expense: Expense) async throws {
        try await perform(.updateExpense(expense), as: nil)
    }

    /// Soft-deletes (tombstones) an expense. It stops affecting balances but keeps its history.
    func delete(_ id: ExpenseID) async throws {
        try await perform(.deleteExpense(id), as: nil)
    }

    /// Undoes a deletion.
    func restore(_ id: ExpenseID) async throws {
        try await perform(.restoreExpense(id), as: nil)
    }
}

/// Confirmed external payments (overview: `SettlementRepository`).
protocol SettlementRepository: LedgerCommandPerforming {}

extension SettlementRepository {
    /// Records an already-confirmed payment directly. Payments made through Square Up's flow
    /// are finalised by confirming a `PaymentAttempt` instead.
    func record(_ settlement: Settlement) async throws {
        try await perform(.recordSettlement(settlement), as: nil)
    }
}

/// How members accept payment. Only the owner may change their destinations.
protocol PaymentDestinationRepository: LedgerCommandPerforming {}

extension PaymentDestinationRepository {
    func save(_ destination: PaymentDestination) async throws {
        try await perform(.saveDestination(destination), as: nil)
    }

    func deleteDestination(_ id: PaymentDestinationID) async throws {
        try await perform(.deleteDestination(id), as: nil)
    }
}

/// The payment-attempt lifecycle. Confirmation is idempotent and creates at most one settlement.
protocol PaymentAttemptRepository: LedgerCommandPerforming {}

extension PaymentAttemptRepository {
    func startPayment(_ request: PaymentRequest) async throws -> PaymentAttempt {
        guard let attempt = try await perform(.startPayment(request), as: nil).attempt else { throw LedgerError.unavailable }
        return attempt
    }

    @discardableResult
    func advance(_ id: PaymentAttemptID, _ action: PaymentAttemptAction, as actor: MemberID? = nil) async throws -> LedgerCommandResult {
        try await perform(.advancePayment(id, action), as: actor)
    }
}

/// Prototype-only maintenance for seeded demonstration data.
protocol SampleDataManaging: LedgerCommandPerforming {
    func resetToSampleData(referenceDate: Date) async throws
    func eraseAll() async throws
}

extension SampleDataManaging {
    /// PROTOTYPE: switch which sample person is using this device. Not multi-device sync.
    func switchCurrentUser(to memberID: MemberID) async throws {
        try await perform(.switchCurrentUser(memberID), as: nil)
    }
}

/// Receipt drafts and Live Receipt Rooms (milestone 3 §11 `ReceiptRoomRepository` and
/// `ReceiptFinalizing`). Commands go through the same engine and transaction as every other
/// ledger change, so finalization and expense creation are one atomic write.
protocol ReceiptRoomRepository: LedgerCommandPerforming, LedgerReading {}

extension ReceiptRoomRepository {
    func room(_ id: ReceiptRoomID) async throws -> ReceiptRoom {
        guard let room = try await snapshot().room(id) else { throw LedgerError.receipt(.roomNotFound) }
        return room
    }

    /// Runs a room command. `actor` is the acting (possibly simulated) participant; `nil` = this device's user.
    @discardableResult
    func run(_ command: ReceiptRoomCommand, as actor: MemberID? = nil) async throws -> LedgerCommandResult {
        try await perform(.receipt(command), as: actor)
    }

    /// Idempotent: a repeat returns the same expense identifier and creates nothing.
    func finalize(_ id: ReceiptRoomID, expectedRevision: Int) async throws -> ExpenseID {
        guard let expenseID = try await run(.finalize(id, expectedRevision: expectedRevision)).expenseID else {
            throw LedgerError.unavailable
        }
        return expenseID
    }
}

/// Milestone 7: a store that can hide a local group once it is published as a shared group.
protocol PublishedGroupMarking: AnyObject {
    func markPublished(_ groupID: GroupID) async throws
}

extension SwiftDataLedgerStore: PublishedGroupMarking {}
extension InMemoryLedgerStore: PublishedGroupMarking {}

/// Everything the app shell injects. Features should depend on the narrowest facet they need.
typealias LedgerStore = ExpenseRepository & GroupRepository & LedgerReading & PaymentAttemptRepository
    & PaymentDestinationRepository & ReceiptRoomRepository & SampleDataManaging & SettlementRepository
