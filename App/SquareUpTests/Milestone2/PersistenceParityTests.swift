import Foundation
@testable import SquareUp
import SwiftData
import Testing

/// Runs the same command script against both stores and against relaunched SwiftData stores.
@Suite("M2 persistence parity", .serialized)
@MainActor
struct PersistenceParityTests {
    let now = DemoScenario.fixedReferenceDate

    private func swiftDataStore(url: URL? = nil, ids: SequentialIDs) throws -> SwiftDataLedgerStore {
        let container = try url.map { try ModelContainerFactory.make(url: $0) } ?? ModelContainerFactory.make(inMemory: true)
        let store = SwiftDataLedgerStore(container: container, now: { DemoScenario.fixedReferenceDate }, makeID: ids.make)
        try store.seedIfEmpty(referenceDate: now)
        return store
    }

    /// A script touching every M2 command type.
    private func script(_ store: any LedgerStore) async throws {
        let groupID = try await store.createGroup(GroupDraft(
            name: "Weekend Trip", details: "Big Sur", symbolName: "car.fill",
            newMembers: [MemberDraft(displayName: "Taylor Kim")], existingMemberIDs: [People.maya]
        ))
        let snapshot = try await store.snapshot()
        let taylor = try #require(snapshot.group(groupID)?.memberIDs.last)
        try await store.add(Expense(
            id: ExpenseID(UUID(uuidString: "77777777-0000-4000-8000-000000000001")!), groupID: groupID, title: "Gas", date: now,
            total: dollars("90.00"), category: .transport, splitMethod: .equal,
            payments: [Share(People.riley, dollars("60.00")), Share(People.maya, dollars("30.00"))],
            allocations: [Share(People.riley, dollars("30.00")), Share(People.maya, dollars("30.00")), Share(taylor, dollars("30.00"))],
            createdBy: People.riley
        ))
        var edited = try #require(try await store.snapshot().expense(ExpenseID(UUID(uuidString: "77777777-0000-4000-8000-000000000001")!)))
        edited.title = "Gas & tolls"
        try await store.update(edited)
        try await store.setSimplification(false, for: groupID)
        // Riley pays Maya in the apartment; Maya confirms.
        let attempt = try await store.startPayment(PaymentRequest(groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya,
                                                                  amount: dollars("29.69"), provider: .paypal, destinationID: nil))
        try await store.advance(attempt.id, .openHandoff)
        try await store.advance(attempt.id, .reportSent(externalReference: "TX-1"))
        try await store.advance(attempt.id, .confirm, as: People.maya)
        try await store.advance(attempt.id, .confirm, as: People.maya) // idempotent repeat
        // Wi-Fi deleted.
        try await store.delete(expense("Wi-Fi", in: try store.snapshot()).id)
        try await store.save(PaymentDestination(id: PaymentDestinationID(UUID(uuidString: "77777777-0000-4000-8000-000000000002")!),
                                                ownerID: People.riley, provider: .cash, value: .instructions("Cash"), createdAt: now))
    }

    private func normalized(_ snapshot: LedgerSnapshot) -> [String] {
        // Order-independent comparison of every entity.
        [
            snapshot.groups.map { "\($0)" }.sorted().joined(),
            snapshot.allExpenses.map { "\($0)" }.sorted().joined(),
            snapshot.settlements.map { "\($0)" }.sorted().joined(),
            snapshot.paymentAttempts.map { "\($0)" }.sorted().joined(),
            snapshot.paymentDestinations.map { "\($0.id)\($0.isPreferred)\($0.isEnabled)\($0.provider)" }.sorted().joined(),
            snapshot.events.map { "\($0.sequence)|\($0.kind)" }.joined(),
            snapshot.members.keys.map(\.description).sorted().joined(),
            "\(snapshot.currentUserID)",
        ]
    }

    @Test("In-memory and SwiftData stores produce identical ledgers")
    func parity() async throws {
        let memory = InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate }, makeID: SequentialIDs(start: 500).make)
        let swiftData = try swiftDataStore(ids: SequentialIDs(start: 500))
        try await script(memory)
        try await script(swiftData)
        let lhs = try await memory.snapshot()
        let rhs = try await swiftData.snapshot()
        #expect(normalized(lhs) == normalized(rhs))
        #expect(lhs.settlements.filter { $0.attemptID != nil }.count == 1, "Confirmation finalised exactly one settlement")
    }

    @Test("Destinations, attempts in every non-terminal state, tombstones, and history survive relaunch")
    func relaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "squareup-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        var ids: [PaymentAttemptState: PaymentAttemptID] = [:]
        do {
            let store = try swiftDataStore(url: url, ids: SequentialIDs(start: 700))
            // methodSelected (Tahoe: Riley isn't a payer there, so use Jordan → Maya as Jordan).
            let selected = try await store.startPayment(PaymentRequest(groupID: Groups.apartment, payerID: People.riley,
                                                                       recipientID: People.maya, amount: dollars("10.00"), provider: .venmo, destinationID: nil))
            ids[.methodSelected] = selected.id
            try await store.switchCurrentUser(to: People.jordan)
            let opened = try await store.startPayment(PaymentRequest(groupID: Groups.apartment, payerID: People.jordan,
                                                                     recipientID: People.maya, amount: dollars("40.47"), provider: .cashApp, destinationID: nil))
            try await store.advance(opened.id, .openHandoff)
            ids[.handoffOpened] = opened.id
            try await store.switchCurrentUser(to: People.riley)
            ids[.reportedSent] = try await store.snapshot().paymentAttempts.first { $0.state == .reportedSent }?.id
            try await store.delete(expense("Nopa dinner", in: try store.snapshot()).id)
        }
        // Relaunch: a brand-new container on the same file.
        let reopened = try swiftDataStore(url: url, ids: SequentialIDs(start: 900))
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.attempt(ids[.methodSelected]!)?.state == .methodSelected)
        #expect(snapshot.attempt(ids[.handoffOpened]!)?.state == .handoffOpened)
        #expect(snapshot.attempt(ids[.reportedSent]!)?.state == .reportedSent)
        #expect(snapshot.paymentDestinations.count == sample().paymentDestinations.count)
        #expect(snapshot.destination(destination(of: People.maya, .appleCash, in: sample())!.id)?.value == .phone("+15305554821"))
        let nopa = expense("Nopa dinner", in: snapshot)
        #expect(nopa.isDeleted)
        #expect(!snapshot.expenses.contains { $0.id == nopa.id })
        #expect(snapshot.events.contains { if case .expenseDeleted(let id, _) = $0.kind { id == nopa.id } else { false } })
        #expect(snapshot.currentUserID == People.riley)

        // Rejection after relaunch releases the reservation.
        let reported = try #require(ids[.reportedSent])
        try await reopened.advance(reported, .reject(reason: nil))
        let group = try #require(try await reopened.snapshot().group(Groups.tahoe))
        let after = try await reopened.snapshot()
        let plan = SettlementPlanner.plan(for: group, expenses: after.expenses(in: group.id), settlements: after.settlements(in: group.id),
                                          attempts: after.attempts(in: group.id))
        #expect(plan.pending.isEmpty)
        #expect(plan.payment(from: People.alexRivera, to: People.riley)?.amount == dollars("417.10"))
    }

    @Test("A failing store saves nothing and reports an error")
    func failure() async {
        let store = InMemoryLedgerStore(sample())
        store.failure = .storage("Disk")
        await #expect(throws: LedgerError.storage("Disk")) { try await store.createGroup(GroupDraft(name: "X")) }
    }
}
