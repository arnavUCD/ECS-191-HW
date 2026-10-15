import Foundation
@testable import SquareUp
import SwiftData
import Testing

private func usd(_ text: String) -> Money { Money(string: text)! }
private let reference = DemoScenario.fixedReferenceDate

@Suite("SwiftData ledger store")
@MainActor
struct SwiftDataLedgerStoreTests {
    private func makeStore() throws -> SwiftDataLedgerStore {
        let store = SwiftDataLedgerStore(container: try ModelContainerFactory.make(inMemory: true))
        try store.seedIfEmpty(referenceDate: reference)
        return store
    }

    @Test("Seeded data round-trips through SwiftData unchanged")
    func roundTrip() async throws {
        let store = try makeStore()
        let stored = try await store.snapshot()
        let original = SampleLedger.make(referenceDate: reference)
        #expect(stored.currentUserID == original.currentUserID)
        #expect(Set(stored.groups) == Set(original.groups))
        #expect(Set(stored.expenses) == Set(original.expenses))
        #expect(Set(stored.settlements) == Set(original.settlements))
        #expect(stored.members == original.members)
        #expect(HomeSummaryBuilder.build(from: stored) == HomeSummaryBuilder.build(from: original))
    }

    @Test("Seeding is idempotent")
    func seedOnce() async throws {
        let store = try makeStore()
        try store.seedIfEmpty(referenceDate: reference)
        #expect(try await store.snapshot().expenses.count == SampleLedger.make(referenceDate: reference).expenses.count)
    }

    @Test("An unreconciled expense is rejected and nothing is persisted")
    func rejectsInvalid() async throws {
        let store = try makeStore()
        let before = try await store.snapshot().expenses.count
        let startRevision = store.revision
        let bad = Expense(
            groupID: SampleLedger.GroupKey.apartment.id, title: "Bad", date: reference, total: usd("10.00"),
            category: .other, splitMethod: .exact, payments: [Share(SampleLedger.Person.riley.id, usd("10.00"))],
            allocations: [Share(SampleLedger.Person.maya.id, usd("4.00"))], createdBy: SampleLedger.Person.riley.id
        )
        await #expect(throws: LedgerError.invalidExpense(.allocationsDoNotReconcile(remaining: usd("6.00")))) {
            try await store.add(bad)
        }
        #expect(try await store.snapshot().expenses.count == before)
        #expect(store.revision == startRevision, "A rejected save must not notify observers")
    }

    @Test("Valid expenses and settlements persist and bump the revision")
    func persistsValid() async throws {
        let store = try makeStore()
        let startRevision = store.revision
        let riley = SampleLedger.Person.riley.id
        let maya = SampleLedger.Person.maya.id
        let expense = Expense(
            groupID: SampleLedger.GroupKey.apartment.id, title: "Soap", date: reference, total: usd("6.00"),
            category: .groceries, splitMethod: .equal, payments: [Share(riley, usd("6.00"))],
            allocations: [Share(riley, usd("3.00")), Share(maya, usd("3.00"))], createdBy: riley
        )
        try await store.add(expense)
        try await store.record(Settlement(groupID: SampleLedger.GroupKey.apartment.id, fromID: riley, toID: maya,
                                          amount: usd("29.69"), date: reference, recordedBy: riley))
        #expect(store.revision == startRevision + 2)
        let snapshot = try await store.snapshot()
        #expect(snapshot.expenses.contains(expense))
        let apartment = try #require(snapshot.group(SampleLedger.GroupKey.apartment.id))
        let ledger = BalanceCalculator.ledger(for: apartment, expenses: snapshot.expenses(in: apartment.id),
                                              settlements: snapshot.settlements(in: apartment.id))
        #expect(ledger.netOwed(from: maya, to: riley) == usd("3.00"))
    }

    @Test("Unknown groups are reported")
    func unknownGroup() async throws {
        let store = try makeStore()
        await #expect(throws: LedgerError.groupNotFound) { try await store.group(GroupID()) }
    }

    @Test("Reset restores the sample; erase empties the store")
    func resetAndErase() async throws {
        let store = try makeStore()
        try await store.eraseAll()
        await #expect(throws: LedgerError.currentUserMissing) { try await store.snapshot() }
        try await store.resetToSampleData(referenceDate: reference)
        let restored = try await store.snapshot()
        #expect(restored.groups.count == 4)
        #expect(Set(restored.expenses) == Set(SampleLedger.make(referenceDate: reference).expenses))
    }
}

@Suite("Home state machine")
@MainActor
struct HomeModelTests {
    @Test("Loads into a summary")
    func loads() async {
        let model = HomeModel(ledger: InMemoryLedgerStore(SampleLedger.make(referenceDate: reference)), now: { reference })
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.summary?.position.net == usd("884.61")) // the P2P sample (see HomeSummaryTests)
        #expect(model.lastUpdated == reference)
    }

    @Test("A first-load failure shows the error state")
    func failsInitially() async {
        let store = InMemoryLedgerStore(nil)
        store.failure = .storage("Disk")
        let model = HomeModel(ledger: store, now: { reference })
        await model.load()
        #expect(model.phase == .failed(.storage("Disk")))
    }

    @Test("A refresh failure keeps existing content instead of blanking it")
    func refreshFailureKeepsContent() async {
        let store = InMemoryLedgerStore(SampleLedger.make(referenceDate: reference))
        let model = HomeModel(ledger: store, now: { reference })
        await model.load()
        store.failure = .unavailable
        await model.load()
        #expect(model.summary != nil)
        #expect(model.refreshError == .unavailable)
        store.failure = nil
        await model.load()
        #expect(model.refreshError == nil)
    }

    @Test("Greeting follows the time of day")
    func greeting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let model = HomeModel(ledger: InMemoryLedgerStore(nil), now: { reference })
        #expect(model.greeting(calendar: calendar) == "Good afternoon")
    }
}
