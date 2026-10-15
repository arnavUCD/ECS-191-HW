import Foundation
import Observation

/// A deterministic, non-persistent ledger for previews, tests, and visual QA scenarios.
///
/// Every mutation runs through `LedgerEngine`, exactly like `SwiftDataLedgerStore`, so tests
/// written against it exercise the real rules. `failure` and `latency` simulate error and
/// loading states.
@Observable
final class InMemoryLedgerStore: LedgerStore {
    private(set) var revision = 0
    @ObservationIgnored private var state: LedgerSnapshot?
    /// When set, every call throws this error (error-state previews and tests).
    @ObservationIgnored var failure: LedgerError?
    /// Artificial delay before each call returns (loading-state previews).
    @ObservationIgnored var latency: Duration = .zero
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeID: () -> UUID

    init(_ snapshot: LedgerSnapshot?, now: @escaping () -> Date = { .now }, makeID: @escaping () -> UUID = UUID.init) {
        state = snapshot
        self.now = now
        self.makeID = makeID
    }

    func snapshot() async throws -> LedgerSnapshot {
        try await simulate()
        guard let state else { throw LedgerError.currentUserMissing }
        return state
    }

    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult {
        try await simulate()
        guard let state else { throw LedgerError.currentUserMissing }
        let result = try LedgerEngine.perform(command, on: state, actor: actor ?? state.currentUserID, now: now(), makeID: makeID)
        if !result.isNoOp {
            self.state = LedgerEngine.apply(result.changes, to: state)
            revision += 1
        }
        return result
    }

    /// Milestone 7: hides a group that was published as a shared group (see `SwiftDataLedgerStore`).
    func markPublished(_ groupID: GroupID) async throws {
        guard let state else { return }
        self.state = LedgerSnapshot(
            currentUserID: state.currentUserID, members: Array(state.members.values), groups: state.groups.filter { $0.id != groupID },
            expenses: state.allExpenses.filter { $0.groupID != groupID }, settlements: state.settlements.filter { $0.groupID != groupID },
            paymentDestinations: state.paymentDestinations, paymentAttempts: state.paymentAttempts.filter { $0.groupID != groupID },
            events: state.events.filter { $0.groupID != groupID }, defaultCurrency: state.defaultCurrency,
            receiptRooms: state.receiptRooms.filter { $0.groupID != groupID }
        )
        revision += 1
    }

    func resetToSampleData(referenceDate: Date) async throws {
        try await simulate()
        state = SampleLedger.make(referenceDate: referenceDate)
        revision += 1
    }

    func eraseAll() async throws {
        try await simulate()
        state = nil
        revision += 1
    }

    private func simulate() async throws {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if let failure { throw failure }
    }
}

extension InMemoryLedgerStore: LocalIdentityPreparing {
    func prepareCurrentUser(id: MemberID, displayName: String) async throws {
        guard let current = state, current.members[current.currentUserID] != nil else {
            state = LedgerSnapshot(currentUserID: id, members: [Member(id: id, displayName: displayName)], groups: [], expenses: [], settlements: [])
            revision += 1
            return
        }
        guard current.currentUserID == id, current.members[id]?.displayName != displayName else { return }
        state = LedgerEngine.apply([.upsertMember(Member(id: id, displayName: displayName))], to: current)
        revision += 1
    }
}

extension InMemoryLedgerStore: LocalDataInspecting {
    func holdsGroupsOrExpenses() -> Bool {
        guard let state else { return false }
        return !state.groups.isEmpty || !state.allExpenses.isEmpty
    }
}
