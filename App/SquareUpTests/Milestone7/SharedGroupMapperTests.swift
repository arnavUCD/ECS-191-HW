import Foundation
@testable import SquareUp
import SwiftData
import Testing

/// Milestone 7: mapping between the shared-group wire format and the app's ledger model.
@Suite("Shared groups · mapping")
struct SharedGroupMapperTests {
    typealias Fix = SharedFixtures

    @Test("A snapshot maps to a workspace with this account's seat as the current user")
    func workspace() throws {
        let groceries = Fix.expense(total: 9000, shares: [(Fix.riley, 3000), (Fix.maya, 3000), (Fix.dev, 3000)], method: "equal")
        let dto = Fix.snapshot(expenses: [groceries])
        let workspace = try SharedGroupMapper.workspace(dto)
        #expect(workspace.currentUserID == Fix.maya)
        let group = try #require(workspace.group(Fix.groupID))
        #expect(group.memberIDs == [Fix.riley, Fix.maya, Fix.dev], "membership order is the server's seat order")
        #expect(group.isActiveMember(Fix.dev), "a seat waiting to join can still share expenses")
        #expect(workspace.expenses.count == 1 && workspace.expenses[0].total == Money(minorUnits: 9000))
        #expect(SharedGroupMapper.balancesAgree(workspace, server: dto.balances))
    }

    @Test("Balances that don't match the app's own calculation are refused")
    func tamperedBalances() throws {
        let dto = Fix.snapshot(expenses: [Fix.expense(total: 9000, shares: [(Fix.riley, 4500), (Fix.maya, 4500)])])
        var tampered = dto.balances
        tampered = GroupBalancesDTO(simplified: tampered.simplified, payments: tampered.payments, directPaymentCount: tampered.directPaymentCount,
                                    simplifiedPaymentCount: tampered.simplifiedPaymentCount, pendingAttemptIds: [],
                                    confirmedNets: tampered.confirmedNets.mapValues { $0 + 1 }, availableNets: tampered.availableNets)
        #expect(!SharedGroupMapper.balancesAgree(try SharedGroupMapper.workspace(dto), server: tampered))
    }

    @Test("Malformed records fail the whole mapping")
    func malformed() {
        var dto = Fix.snapshot(expenses: [Fix.expense(total: 100, shares: [(Fix.maya, 100)])])
        dto.expenses = [GroupExpenseDTO(id: "not-a-uuid", title: "x", merchant: nil, date: Fix.createdAt, total: 100, category: "food", splitMethod: "equal",
                                        payments: [], allocations: [], note: nil, createdBy: Fix.id(Fix.riley), createdAt: Fix.createdAt, revision: 1,
                                        updatedAt: nil, updatedBy: nil, deletedAt: nil, deletedBy: nil, receipt: nil, receiptOmitted: nil, roomId: nil)]
        #expect(throws: SharedGroupMapper.Failure.self) { try SharedGroupMapper.workspace(dto) }
        var unknownMethod = Fix.snapshot()
        unknownMethod.expenses = [Fix.expense(total: 100, shares: [(Fix.maya, 100)], method: "hybrid")]
        #expect(throws: SharedGroupMapper.Failure.self) { try SharedGroupMapper.workspace(unknownMethod) }
    }

    @Test("A change page applies only when it continues the cursor without gaps")
    func changePages() throws {
        let base = Fix.snapshot(events: [Fix.event(1, "groupCreated", data: ["name": "Coastal Weekend"])])
        let expense = Fix.expense(total: 600, shares: [(Fix.riley, 300), (Fix.maya, 300)])
        let next = Fix.snapshot(revision: 4, expenses: [expense], events: base.events + [
            Fix.event(2, "expenseCreated", data: ["expenseId": .string(expense.id), "title": "Groceries", "total": 600]),
        ])
        let page = Fix.changes(from: base, to: next)
        let applied = try #require(SharedGroupMapper.applying(page, to: base))
        #expect(applied.expenses == [expense] && applied.cursor == 2 && applied.events.count == 2)
        var gap = page
        gap = GroupChangesDTO(schemaVersion: 1, serverTime: gap.serverTime, revision: gap.revision, after: 0, cursor: gap.cursor, cursorExpired: false,
                              group: gap.group, viewer: gap.viewer, members: gap.members, expenses: gap.expenses, settlements: [], attempts: [],
                              balances: gap.balances, events: gap.events)
        #expect(SharedGroupMapper.applying(gap, to: base) == nil, "a page from a different cursor is never guessed into place")
        let expired = GroupChangesDTO(schemaVersion: 1, serverTime: Fix.createdAt, revision: 9, after: 1, cursor: 400, cursorExpired: true, group: nil,
                                      viewer: nil, members: nil, expenses: nil, settlements: nil, attempts: nil, balances: nil, events: nil)
        #expect(SharedGroupMapper.applying(expired, to: base) == nil)
    }

    @Test("Server events become audit events; unknown kinds are skipped")
    func events() throws {
        let events = [
            Fix.event(1, "groupPublished", data: ["name": "Coastal"]),
            Fix.event(2, "memberJoined", actor: Fix.maya, data: ["memberId": .string(Fix.id(Fix.maya))]),
            Fix.event(3, "paymentHandoffOpened", actor: Fix.maya, data: ["attemptId": .string(UUID().uuidString), "payerId": .string(Fix.id(Fix.maya)),
                                                                         "recipientId": .string(Fix.id(Fix.riley)), "amount": 2500, "provider": "venmo"]),
            Fix.event(4, "somethingFromTheFuture"),
        ]
        let workspace = try SharedGroupMapper.workspace(Fix.snapshot(events: events))
        let kinds = workspace.events.map(\.kind)
        #expect(kinds.count == 3)
        #expect(kinds[0] == .groupPublished(name: "Coastal") && kinds[1] == .memberJoined(Fix.maya))
        guard case .paymentHandoffOpened(let info) = kinds[2] else { Issue.record("Expected handoff opened"); return }
        #expect(info.amount == Money(minorUnits: 2500) && info.provider == .venmo)
        let text = AuditEventPresenter.describe(workspace.events[2], members: workspace.members, currentUserID: Fix.maya).detail ?? ""
        #expect(text.contains("doesn't mean money was sent"), "opening an app is never described as a payment")
    }

    @Test("Destination links outside the provider allowlist are dropped")
    func destinations() {
        let safe = DestinationDTO(id: UUID().uuidString, provider: "cashApp", value: DestinationValueDTO(kind: "username", value: "MayaC"),
                                  link: "https://evil.example/$MayaC", label: nil, isEnabled: true, isPreferred: true, createdAt: nil, updatedAt: nil)
        let mapped = SharedGroupMapper.destination(safe, owner: Fix.maya)
        #expect(mapped?.link == nil && mapped?.value == .username("MayaC"))
        let badValue = DestinationDTO(id: UUID().uuidString, provider: "paypal", value: DestinationValueDTO(kind: "link", value: "javascript:alert(1)"),
                                      link: nil, label: nil, isEnabled: true, isPreferred: false, createdAt: nil, updatedAt: nil)
        #expect(SharedGroupMapper.destination(badValue, owner: Fix.maya) == nil)
    }

    @Test("Expense commands carry how the split was entered, so the server can recompute it")
    func expensePayload() {
        var expense = Expense(groupID: Fix.groupID, title: "Dinner", date: .now, total: Money(minorUnits: 1001), category: .food, splitMethod: .percentage,
                              payments: [Share(Fix.riley, Money(minorUnits: 1001))],
                              allocations: [Share(Fix.riley, Money(minorUnits: 334)), Share(Fix.maya, Money(minorUnits: 667))], createdBy: Fix.riley)
        expense.splitInput = .percentage([MemberPercent(Fix.riley, Decimal(string: "33.34")!), MemberPercent(Fix.maya, Decimal(string: "66.66")!)])
        let payload = SharedGroupMapper.expensePayload(expense, previous: nil)
        #expect(payload["split"]?["method"] == "percentage")
        guard case .array(let percentages) = payload["split"]?["percentages"] ?? .null else { Issue.record("no percentages"); return }
        #expect(percentages.compactMap { $0["percent"]?.stringValue } == ["33.34", "66.66"])
        #expect(payload["expense"]?["total"] == .int(1001) && payload["expenseId"] == nil)
    }

    @Test("Invitation codes are read from the app link, the web page, or pasted text — nothing else")
    func invitationCodes() {
        let configuration = RemoteConfiguration.make(scheme: "https", host: "squareup.example", authMode: "firebase", firebaseAPIKey: "test")
        let code = "K7QD3MRA9XTVG2PNH4WE"
        #expect(SharedGroupsService.invitationCode(from: "squp://join-group/\(code)", configuration: configuration) == code)
        #expect(SharedGroupsService.invitationCode(from: "https://squareup.example/g/\(code)", configuration: configuration) == code)
        #expect(SharedGroupsService.invitationCode(from: " k7qd-3mra-9xtv-g2pn-h4we \n", configuration: configuration) == code)
        #expect(SharedGroupsService.invitationCode(from: "https://other.example/g/\(code)", configuration: configuration) == nil)
        #expect(SharedGroupsService.invitationCode(from: "squp://join/\(code)", configuration: configuration) == nil)
        #expect(SharedGroupsService.invitationCode(from: "K7QD-3MRA", configuration: configuration) == nil)
        #expect(SharedGroupsService.displayCode(code) == "K7QD-3MRA-9XTV-G2PN-H4WE")
    }
}

/// Milestone 7 §8: what may be published from a local group, and what is sent.
@MainActor
@Suite("Shared groups · publishing")
struct PublicationTests {
    @Test("A sample group with nothing in progress passes review; the request keeps every local ID")
    func samplePublication() throws {
        let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
        let tahoe = SampleLedger.GroupKey.apartment.id
        let review = SharedGroupsService.review(tahoe, in: snapshot)
        #expect(review.canPublish, "\(review.blockers)")
        let request = SharedGroupsService.publication(tahoe, in: snapshot, publicationID: "p-1")
        let group = try #require(snapshot.group(tahoe))
        #expect(request.group.id == SharedGroupMapper.id(tahoe))
        #expect(request.members.map(\.id) == group.memberIDs.map(SharedGroupMapper.id), "every person keeps their ID and order")
        #expect(Set(request.expenses.map(\.id)) == Set(snapshot.allExpenses.filter { $0.groupID == tahoe }.map { SharedGroupMapper.id($0.id) }))
        #expect(request.publisherMemberId == SharedGroupMapper.id(snapshot.currentUserID))
        #expect(!request.events.contains { $0.kind.hasPrefix("payment") && $0.kind != "paymentConfirmed" }, "payment drafts stay on the device")
        let encoded = try #require(String(bytes: JSONEncoder().encode(request), encoding: .utf8))
        #expect(!encoded.contains("organization") && !encoded.contains("funding"))
    }

    @Test("Open payments and unfinished receipts block publishing; nothing is half-shared")
    func blockers() {
        let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
        // The sample Tahoe group has a payment Alex reported sending Riley, awaiting confirmation.
        let groupsWithOpenPayments = Set(snapshot.paymentAttempts.filter { !$0.state.isTerminal }.map(\.groupID))
        for id in groupsWithOpenPayments {
            #expect(SharedGroupsService.review(id, in: snapshot).blockers.contains { $0.contains("payments in progress") })
        }
        let coastal = SampleLedger.GroupKey.coastal.id
        #expect(SharedGroupsService.review(coastal, in: snapshot).blockers.contains { $0.contains("receipt") },
                "the sample's open Driftwood Kitchen room must be finished or discarded first")
    }

    @Test("A legacy organization group never appears in a snapshot, so it can't be reviewed or published")
    func legacyExcluded() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SwiftDataLedgerStore(container: container)
        try store.seedIfEmpty(referenceDate: DemoScenario.fixedReferenceDate)
        let legacy = GroupRecord(ExpenseGroup(name: "Old Club", symbolName: "building.2", memberships: [], createdAt: .now))
        legacy.kind = LegacyRecords.organizationKind
        container.mainContext.insert(legacy)
        try container.mainContext.save()
        let snapshot = try await store.snapshot()
        let review = SharedGroupsService.review(GroupID(legacy.id), in: snapshot)
        #expect(!review.canPublish && review.blockers.contains { $0.contains("Only your own personal groups") })
    }

    @Test("After publishing, the local copy is set aside, never edited in parallel")
    func localCopyHidden() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SwiftDataLedgerStore(container: container)
        try store.seedIfEmpty(referenceDate: DemoScenario.fixedReferenceDate)
        let tahoe = SampleLedger.GroupKey.tahoe.id
        #expect(try await store.snapshot().group(tahoe) != nil)
        try await store.markPublished(tahoe)
        let after = try await store.snapshot()
        #expect(after.group(tahoe) == nil && !after.allExpenses.contains { $0.groupID == tahoe } && !after.paymentAttempts.contains { $0.groupID == tahoe })
        #expect(after.group(SampleLedger.GroupKey.apartment.id) != nil, "other groups are untouched")
    }
}
