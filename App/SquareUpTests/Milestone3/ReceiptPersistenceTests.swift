import Foundation
@testable import SquareUp
import SwiftData
import Testing

/// Persistence contract (milestone 3 §17.4): the same room scenarios against both stores,
/// relaunch survival, and the deliberate milestone 2 → 3 migration.
@Suite("M3 receipt persistence", .serialized)
@MainActor
struct ReceiptPersistenceTests {
    let roomID = ReceiptRoomID(UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000009")!)

    private func swiftData(url: URL? = nil, start: Int = 600) throws -> SwiftDataLedgerStore {
        let container = try url.map { try ModelContainerFactory.make(url: $0) } ?? ModelContainerFactory.make(inMemory: true)
        let store = SwiftDataLedgerStore(container: container, now: { DemoScenario.fixedReferenceDate }, makeID: SequentialIDs(start: start).make)
        try store.seedIfEmpty(referenceDate: DemoScenario.fixedReferenceDate)
        return store
    }

    private func revision(_ store: any LedgerStore) async throws -> Int { try await store.room(roomID).revision }

    /// Draft → open → claims, a dispute, a stale command, then finalize twice.
    private func script(_ store: any LedgerStore) async throws -> [String] {
        var outcomes: [String] = []
        try await store.run(.createDraft(roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
        try await store.run(.saveDraft(roomID, expectedRevision: revision(store), receipt: ReceiptFixtures.draft(ReceiptFixtures.dinner),
                                       groupID: Groups.friday, payerID: People.riley))
        try await store.run(.confirmReceipt(roomID, expectedRevision: revision(store)))
        try await store.run(.openRoom(roomID, expectedRevision: revision(store), participants: [People.riley, People.maya, People.alexMorgan, People.priya]))
        let room = try await store.room(roomID)
        func item(_ name: String) -> ReceiptItemID { room.receipt.items.first { $0.name.value == name }!.id }
        let claims: [(String, ClaimRequest, MemberID)] = [
            ("Truffle Fries", .share, People.riley), ("Truffle Fries", .share, People.maya), ("Margherita Pizza", .mine, People.alexMorgan),
            ("Caesar Salad", .mine, People.priya), ("Lemonade", .mine, People.maya), ("Mushroom Risotto", .mine, People.riley),
            ("Shared Nachos", .share, People.riley), ("Shared Nachos", .share, People.alexMorgan), ("Shared Nachos", .share, People.priya),
            ("Tiramisu", .mine, People.priya), ("Iced Tea", .mine, People.alexMorgan),
        ]
        for (name, request, actor) in claims {
            try await store.run(.claim(roomID, expectedRevision: revision(store), item: item(name), request), as: actor)
        }
        // Errors match too.
        do {
            try await store.run(.claim(roomID, expectedRevision: 1, item: item("Tiramisu"), .share), as: People.maya)
        } catch {
            outcomes.append("\(error)")
        }
        do {
            try await store.run(.claim(roomID, expectedRevision: revision(store), item: item("Tiramisu"), .mine), as: People.maya)
        } catch {
            outcomes.append("\(error)")
        }
        try await store.run(.dispute(roomID, expectedRevision: revision(store), .item(item("Lemonade")), note: "Shared one"), as: People.priya)
        let dispute = try await store.room(roomID).openDisputes[0].id
        try await store.run(.setItemSplit(roomID, expectedRevision: revision(store), item: item("Lemonade"), .equal([People.maya, People.priya])))
        try await store.run(.resolveDispute(roomID, expectedRevision: revision(store), dispute, .resolved, note: nil))
        try await store.run(.setChargeAllocation(roomID, expectedRevision: revision(store), room.receipt.charges.first { $0.kind == .tip }!.id, .equal(nil)))
        try await store.run(.transition(roomID, expectedRevision: revision(store), .requestFinalReview))
        let finalRevision = try await revision(store)
        let first = try await store.finalize(roomID, expectedRevision: finalRevision)
        let second = try await store.finalize(roomID, expectedRevision: finalRevision)
        outcomes.append(first == second ? "same expense" : "different expenses")
        return outcomes
    }

    @Test("In-memory and SwiftData rooms behave identically, including errors and idempotent finalization")
    func parity() async throws {
        let memory = InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate }, makeID: SequentialIDs(start: 600).make)
        let swiftData = try swiftData()
        let memoryOutcomes = try await script(memory)
        let swiftDataOutcomes = try await script(swiftData)
        #expect(memoryOutcomes == swiftDataOutcomes)
        #expect(memoryOutcomes.count == 3)
        #expect(memoryOutcomes.last == "same expense")
        let lhs = try await memory.snapshot()
        let rhs = try await swiftData.snapshot()
        #expect(lhs.receiptRooms == rhs.receiptRooms)
        #expect(lhs.allExpenses.sorted { $0.id.description < $1.id.description } == rhs.allExpenses.sorted { $0.id.description < $1.id.description })
        #expect(lhs.events == rhs.events)
        #expect(lhs.allExpenses.filter { $0.splitMethod == .itemized }.count == 1)
    }

    @Test("Drafts and open rooms survive relaunch exactly")
    func relaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "squareup-m3-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let draftID = ReceiptRoomID(UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000010")!)
        var before: LedgerSnapshot
        do {
            let store = try swiftData(url: url)
            var draft = ReceiptFixtures.draft(ReceiptFixtures.dinner)
            draft.recognition.status = .inProgress
            try await store.run(.createDraft(draftID, groupID: Groups.friday, pages: [ReceiptFixtures.page()], currency: .usd))
            try await store.run(.saveDraft(draftID, expectedRevision: 1, receipt: draft, groupID: Groups.friday, payerID: nil))
            try await store.run(.createDraft(roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
            try await store.run(.saveDraft(roomID, expectedRevision: revision(store), receipt: ReceiptFixtures.draft(ReceiptFixtures.dinner),
                                           groupID: Groups.friday, payerID: People.maya))
            try await store.run(.confirmReceipt(roomID, expectedRevision: revision(store)))
            try await store.run(.openRoom(roomID, expectedRevision: revision(store), participants: [People.riley, People.maya]))
            let tiramisu = try await store.room(roomID).receipt.items.first { $0.name.value == "Tiramisu" }!.id
            try await store.run(.claim(roomID, expectedRevision: revision(store), item: tiramisu, .mine), as: People.maya)
            before = try await store.snapshot()
        }
        let reopened = try swiftData(url: url, start: 900)
        let after = try await reopened.snapshot()
        #expect(after.receiptRooms == before.receiptRooms)
        #expect(after.room(roomID)?.state == .open)
        #expect(after.room(roomID)?.claims.count == 1)
        // A draft interrupted mid-recognition comes back marked so the person can retry.
        #expect(after.room(draftID)?.receipt.recognition.status == .inProgress)
        // Plus the sample's open Driftwood Kitchen room, which isn't part of this test.
        #expect(after.unfinishedRooms.filter { [roomID, draftID].contains($0.id) }.count == 2)
        #expect(after.unfinishedRooms.count == before.unfinishedRooms.count)
    }

    @Test("A milestone 2 store opens through the migration plan with its data intact")
    func migrationFromMilestone2() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "squareup-v2-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = sample()
        do {
            // Exactly the milestone 2 schema, as shipped (no version metadata, no receipt entity).
            let schema = Schema(SquareUpSchemaV2.models)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            for member in snapshot.members.values {
                context.insert(MemberRecord(member, isCurrentUser: member.id == snapshot.currentUserID))
            }
            var groups: [UUID: GroupRecord] = [:]
            for group in snapshot.groups {
                let record = GroupRecord(group)
                context.insert(record)
                groups[group.id.rawValue] = record
            }
            for expense in snapshot.allExpenses {
                let record = ExpenseRecord(expense)
                context.insert(record)
                record.group = groups[expense.groupID.rawValue]
            }
            for settlement in snapshot.settlements {
                let record = SettlementRecord(settlement)
                context.insert(record)
                record.group = groups[settlement.groupID.rawValue]
            }
            for attempt in snapshot.paymentAttempts {
                context.insert(PaymentAttemptRecord(id: attempt.id.rawValue, groupID: attempt.groupID.rawValue, state: attempt.state.rawValue,
                                                    payload: try PayloadCoding.encode(attempt)))
            }
            for destination in snapshot.paymentDestinations {
                context.insert(PaymentDestinationRecord(id: destination.id.rawValue, ownerID: destination.ownerID.rawValue,
                                                        payload: try PayloadCoding.encode(destination)))
            }
            for event in snapshot.events {
                context.insert(AuditEventRecord(id: event.id.rawValue, groupID: event.groupID.rawValue, sequence: event.sequence,
                                                payload: try PayloadCoding.encode(event)))
            }
            try context.save()
        }
        let migrated = try swiftData(url: url)
        let loaded = try await migrated.snapshot()
        #expect(loaded.groups.count == snapshot.groups.count)
        #expect(Set(loaded.allExpenses.map(\.id)) == Set(snapshot.allExpenses.map(\.id)))
        #expect(loaded.paymentAttempts == snapshot.paymentAttempts)
        #expect(loaded.paymentDestinations.count == snapshot.paymentDestinations.count)
        #expect(loaded.events == snapshot.events)
        #expect(loaded.receiptRooms.isEmpty)
        // And the upgraded store accepts receipt rooms.
        try await migrated.run(.createDraft(roomID, groupID: Groups.friday, pages: [], currency: .usd))
        #expect(try await migrated.snapshot().receiptRooms.count == 1)
    }

    @Test("Reset Sample Data clears rooms")
    func reset() async throws {
        let store = try swiftData()
        try await store.run(.createDraft(roomID, groupID: nil, pages: [], currency: .usd))
        try await store.resetToSampleData(referenceDate: DemoScenario.fixedReferenceDate)
        // The person's rooms are gone; the reset sample brings its own open room.
        #expect(try await store.snapshot().room(roomID) == nil)
        #expect(try await store.snapshot().receiptRooms.map(\.id) == SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate).receiptRooms.map(\.id))
    }
}
