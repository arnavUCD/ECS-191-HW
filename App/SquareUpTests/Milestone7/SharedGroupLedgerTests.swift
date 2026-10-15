import Foundation
@testable import SquareUp
import Testing

/// Milestone 7 §7: the shared-group ledger against a scripted server — pending and offline states,
/// idempotent retries, conflicts, verification, access, and the account-scoped cache.
@MainActor
@Suite("Shared groups · ledger", .serialized)
struct SharedGroupLedgerTests {
    typealias Fix = SharedFixtures

    /// A change page that says "fetch a full snapshot".
    nonisolated static var expiredCursor: Data {
        Fix.json(GroupChangesResponse(changes: GroupChangesDTO(
            schemaVersion: 1, serverTime: Fix.createdAt, revision: 0, after: 0, cursor: 0, cursorExpired: true, group: nil, viewer: nil,
            members: nil, expenses: nil, settlements: nil, attempts: nil, balances: nil, events: nil)))
    }

    private func addExpense(_ ledger: SharedGroupLedger, total: Int = 1000) async throws -> Expense {
        var expense = Expense(groupID: Fix.groupID, title: "Gas", date: Date(timeIntervalSince1970: 1_790_000_000), total: Money(minorUnits: Int64(total)),
                              category: .transport, splitMethod: .equal, payments: [Share(Fix.maya, Money(minorUnits: Int64(total)))],
                              allocations: try SplitCalculator.equal(Money(minorUnits: Int64(total)), among: [Fix.riley, Fix.maya]).shares, createdBy: Fix.maya)
        expense.splitInput = .equal([Fix.riley, Fix.maya])
        try await ledger.perform(.addExpense(expense), as: nil)
        return expense
    }

    @Test("Adding an expense sends one envelope (with the split and cursor) and shows the confirmed result")
    func addsExpense() async throws {
        let base = Fix.snapshot()
        let transport = ScriptedTransport { request, _ in
            guard let body = Fix.body(request), let payload = body["payload"]?["expense"] else { return (500, Data()) }
            let id = payload["id"]?.stringValue ?? ""
            let next = Fix.snapshot(revision: 4, expenses: [Fix.expense(ExpenseID(string: id)!, title: "Gas", total: 1000, payer: Fix.maya,
                                                                        shares: [(Fix.riley, 500), (Fix.maya, 500)], method: "equal", createdBy: Fix.maya)],
                                    events: base.events + [Fix.event(2, "expenseCreated", actor: Fix.maya,
                                                                     data: ["expenseId": .string(id), "title": "Gas", "total": 1000])])
            return (200, Fix.commandResponse(revision: 4, cursor: 2, result: ["expenseId": .string(id)], changes: Fix.changes(from: base, to: next)))
        }
        let ledger = Fix.ledger(transport, initial: base)
        let expense = try await addExpense(ledger)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(Fix.body(requests[0]))
        #expect(body["type"] == "addExpense" && body["knownCursor"] == .int(1) && body["payload"]?["split"]?["method"] == "equal")
        let snapshot = try await ledger.snapshot()
        #expect(snapshot.expense(expense.id)?.total == Money(minorUnits: 1000) && ledger.pendingExpenseIDs.isEmpty)
        #expect(ledger.base?.revision == 4 && ledger.unsent.isEmpty)
        if case .synced = ledger.syncState {} else { Issue.record("Expected synced, got \(ledger.syncState)") }
    }

    @Test("Offline: an ordinary change waits with its key and is resent byte-for-byte")
    func offlineQueue() async throws {
        let base = Fix.snapshot()
        let transport = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let cache = SharedGroupCache(root: nil)
        let ledger = Fix.ledger(transport, initial: base, cache: cache)
        await #expect(throws: LedgerError.remote(.offline)) { _ = try await addExpense(ledger) }
        #expect(ledger.unsent.count == 1 && !ledger.pendingExpenseIDs.isEmpty, "shown as waiting, not as saved")
        if case .offline = ledger.syncState {} else { Issue.record("Expected offline") }
        let firstKey = try #require(ledger.unsent.first?.envelope.idempotencyKey)
        // The waiting change survives a relaunch (same account).
        let relaunched = Fix.ledger(transport, cache: cache)
        #expect(relaunched.unsent.map(\.envelope.idempotencyKey) == [firstKey])

        let sent = ScriptedTransportLog()
        await transport.respond { request, _ in
            if Fix.path(request).hasSuffix("/changes") {
                return (200, Fix.json(GroupChangesResponse(changes: GroupChangesDTO(
                    schemaVersion: 1, serverTime: Fix.createdAt, revision: 3, after: 1, cursor: 1, cursorExpired: false, group: base.group, viewer: base.viewer,
                    members: base.members, expenses: [], settlements: [], attempts: [], balances: base.balances, events: []))))
            }
            guard Fix.path(request).hasSuffix("/commands") else { return (200, Fix.json(GroupSnapshotResponse(snapshot: base))) }
            await sent.record(Fix.body(request)?["idempotencyKey"]?.stringValue)
            return (200, Fix.commandResponse(applied: true, revision: 4, cursor: 1))
        }
        try await ledger.refresh()
        #expect(await sent.keys == [firstKey], "resent once, with the original key")
        #expect(ledger.unsent.isEmpty && ledger.pendingExpenseIDs.isEmpty)
    }

    @Test("Offline: a payment confirmation is never queued; Try again reuses the same key")
    func liveOnly() async throws {
        let attemptID = PaymentAttemptID()
        let attempt = GroupAttemptDTO(id: Fix.id(attemptID), payerId: Fix.id(Fix.riley), recipientId: Fix.id(Fix.maya), destinationId: nil, provider: "cash",
                                      amount: 500, memo: "m", state: "reportedSent",
                                      history: [AttemptTransitionDTO(state: "methodSelected", actorId: Fix.id(Fix.riley), at: Fix.createdAt, note: nil),
                                                AttemptTransitionDTO(state: "reportedSent", actorId: Fix.id(Fix.riley), at: Fix.createdAt, note: nil)],
                                      externalReference: nil, settlementId: nil)
        let base = Fix.snapshot(expenses: [Fix.expense(total: 1000, payer: Fix.maya, shares: [(Fix.riley, 500), (Fix.maya, 500)], createdBy: Fix.maya)],
                                attempts: [attempt])
        let transport = ScriptedTransport { _, _ in throw URLError(.timedOut) }
        let ledger = Fix.ledger(transport, initial: base)
        await #expect(throws: LedgerError.remote(.connectionRequired)) {
            try await ledger.perform(.advancePayment(attemptID, .confirm), as: nil)
        }
        #expect(ledger.unsent.isEmpty, "never queued")
        #expect(await ledger.notice == .connectionRequired(summary: SharedGroupLedger.summary(of: .advancePayment(attemptID, .confirm), in: try ledger.snapshot())))
        #expect(try await ledger.snapshot().settlements.isEmpty, "nothing looks confirmed")
        let firstKey = try #require(ledger.unconfirmed?.envelope.idempotencyKey)
        let keys = ScriptedTransportLog()
        await transport.respond { request, _ in
            guard Fix.path(request).hasSuffix("/commands") else { return (200, Fix.json(GroupSnapshotResponse(snapshot: base))) }
            await keys.record(Fix.body(request)?["idempotencyKey"]?.stringValue)
            return (200, Fix.commandResponse(revision: 4, cursor: 1))
        }
        try await ledger.retryUnconfirmed()
        #expect(await keys.keys == [firstKey] && ledger.unconfirmed == nil)
    }

    @Test("A stale revision refreshes, keeps nothing half-applied, and explains it")
    func conflict() async throws {
        let base = Fix.snapshot(viewer: Fix.riley)
        let transport = ScriptedTransport { request, _ in
            if Fix.path(request).hasSuffix("/commands") { return (409, Fix.refusal(409, "revision_conflict", extra: ["currentRevision": 5, "cursor": 1])) }
            if Fix.path(request).hasSuffix("/changes") { return (200, SharedGroupLedgerTests.expiredCursor) }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: Fix.snapshot(revision: 5, viewer: Fix.riley))))
        }
        let ledger = Fix.ledger(transport, initial: base)
        await #expect(throws: LedgerError.remote(.conflict)) {
            try await ledger.perform(.setSimplification(Fix.groupID, false), as: nil)
        }
        guard case .conflict = ledger.notice else { Issue.record("Expected a conflict notice"); return }
        #expect(ledger.base?.revision == 5, "the latest is showing")
    }

    @Test("Someone else changed the expense: the draft isn't lost and the notice points to the latest")
    func expenseConflict() async throws {
        let id = ExpenseID()
        let base = Fix.snapshot(expenses: [Fix.expense(id, total: 1000, payer: Fix.maya, shares: [(Fix.riley, 500), (Fix.maya, 500)], createdBy: Fix.maya)])
        let transport = ScriptedTransport { request, _ in
            if Fix.path(request).hasSuffix("/commands") { return (409, Fix.refusal(409, "expense_conflict", extra: ["currentRevision": 2])) }
            if Fix.path(request).hasSuffix("/changes") { return (200, SharedGroupLedgerTests.expiredCursor) }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: base)))
        }
        let ledger = Fix.ledger(transport, initial: base)
        var edited = try #require(try await ledger.snapshot().expense(id))
        edited.title = "Gas and snacks"
        await #expect(throws: LedgerError.remote(.conflict)) { try await ledger.perform(.updateExpense(edited), as: nil) }
        #expect(ledger.notice == .expenseChanged(id))
        let sentBody = try #require(await transport.requests.first.flatMap(Fix.body))
        #expect(sentBody["payload"]?["expectedExpenseRevision"] == .int(1))
    }

    @Test("A state whose balances don't add up here is not shown; the last good one stays")
    func unverifiable() async throws {
        let base = Fix.snapshot()
        var tampered = Fix.snapshot(revision: 9, expenses: [Fix.expense(total: 900, shares: [(Fix.riley, 450), (Fix.maya, 450)])])
        tampered.balances = GroupBalancesDTO(simplified: true, payments: [], directPaymentCount: 0, simplifiedPaymentCount: 0, pendingAttemptIds: [],
                                             confirmedNets: [Fix.id(Fix.riley): 0, Fix.id(Fix.maya): 0, Fix.id(Fix.dev): 0], availableNets: [:])
        let bad = tampered
        let transport = ScriptedTransport { request, _ in
            if Fix.path(request).hasSuffix("/changes") {
                return (200, Fix.json(GroupChangesResponse(changes: GroupChangesDTO(
                    schemaVersion: 1, serverTime: Fix.createdAt, revision: 9, after: 1, cursor: 400, cursorExpired: true, group: nil, viewer: nil,
                    members: nil, expenses: nil, settlements: nil, attempts: nil, balances: nil, events: nil))))
            }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: bad)))
        }
        let ledger = Fix.ledger(transport, initial: base)
        try await ledger.refresh()
        #expect(ledger.base?.revision == 3 && ledger.notice == .unreadable)
        #expect(try await ledger.snapshot().expenses.isEmpty)
    }

    @Test("Removed from the group: access ends and polling stops")
    func removed() async throws {
        let transport = ScriptedTransport { _, _ in (403, Fix.refusal(403, "not_a_member")) }
        let ledger = Fix.ledger(transport, initial: Fix.snapshot())
        await #expect(throws: LedgerError.remote(.removedFromGroup)) { try await ledger.refresh() }
        #expect(ledger.syncState == .accessEnded && !ledger.isPolling)
    }

    @Test("Commands are checked locally first: nothing is sent when the split doesn't add up")
    func localValidation() async throws {
        let transport = ScriptedTransport { _, _ in (500, Data()) }
        let ledger = Fix.ledger(transport, initial: Fix.snapshot())
        let wrong = Expense(groupID: Fix.groupID, title: "Bad", date: .now, total: Money(minorUnits: 1000), category: .other, splitMethod: .exact,
                            payments: [Share(Fix.maya, Money(minorUnits: 1000))], allocations: [Share(Fix.maya, Money(minorUnits: 900))], createdBy: Fix.maya)
        await #expect(throws: LedgerError.self) { try await ledger.perform(.addExpense(wrong), as: nil) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Everyone acts as themselves: no sample-identity switching in a shared group")
    func noImpersonation() async throws {
        let transport = ScriptedTransport { _, _ in (500, Data()) }
        let ledger = Fix.ledger(transport, initial: Fix.snapshot())
        await #expect(throws: LedgerError.self) { try await ledger.perform(.setSimplification(Fix.groupID, false), as: Fix.riley) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("The cache is per account; signing out removes this account's copies only")
    func cacheSeparation() {
        let cache = SharedGroupCache(root: nil)
        let entry = SharedGroupCache.GroupEntry(snapshot: Fix.snapshot(), cachedAt: .now)
        cache.save(entry, group: Fix.groupID, account: "account-a")
        #expect(cache.group(Fix.groupID, account: "account-a") != nil)
        #expect(cache.group(Fix.groupID, account: "account-b") == nil, "another account never sees it")
        cache.save(entry, group: Fix.groupID, account: "account-b")
        cache.purge(account: "account-a")
        #expect(cache.group(Fix.groupID, account: "account-a") == nil && cache.group(Fix.groupID, account: "account-b") != nil)
        #expect(cache.cachedGroupIDs(account: "account-b") == [Fix.groupID])
    }

    @Test("The on-disk cache is protected, excluded from backups, and namespaced by a hash")
    func diskCache() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "shared-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SharedGroupCache(root: root)
        cache.save(SharedGroupCache.GroupEntry(snapshot: Fix.snapshot(), cachedAt: .now), group: Fix.groupID, account: "firebase-uid-123")
        let directories = try FileManager.default.contentsOfDirectory(atPath: root.path())
        #expect(directories.count == 1 && !directories[0].contains("firebase-uid-123"), "the account ID never appears in a path")
        let directory = root.appending(path: directories[0])
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(cache.group(Fix.groupID, account: "firebase-uid-123") != nil)
        cache.purge(account: "firebase-uid-123")
        #expect(!FileManager.default.fileExists(atPath: directory.path()))
    }
}

/// Records values from inside a scripted transport.
actor ScriptedTransportLog {
    private(set) var keys: [String?] = []
    func record(_ key: String?) { keys.append(key) }
}
