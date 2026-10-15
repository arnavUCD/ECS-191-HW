import Foundation
@testable import SquareUp
import Testing

/// Milestone 4 §7 and §14.3 against a mock server: commands carry the envelope, previews stay
/// pending until confirmed, conflicts and offline failures are explained and recoverable, and a
/// person's own quick taps never conflict with each other.
@MainActor @Suite("Remote room session")
struct RemoteRoomTests {
    typealias Fix = RemoteFixtures

    @Test func commandCarriesEnvelopeAndShowsTheConfirmedRoom() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            return (200, Fix.commandBody(Fix.room(revision: 4, claims: [Fix.claim(Fix.fries, by: Fix.guest)])))
        }
        let session = Fix.session(transport)
        let snapshot = try await session.snapshot()
        #expect(snapshot.currentUserID == Fix.guest)
        #expect(snapshot.room(Fix.roomID)?.revision == 3)

        try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine))

        let envelope = try #require(await transport.envelopes.first)
        #expect(envelope.type == "claim")
        #expect(envelope.expectedRevision == 3)
        #expect((8...64).contains(envelope.idempotencyKey.count))
        #expect(UUID(uuidString: envelope.commandId) != nil)
        #expect(envelope.payload == ["itemId": .string(Fix.id(Fix.fries)), "request": "mine"])
        let request = try #require(await transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Guest guest-credential")
        #expect(Fix.path(request).hasSuffix("/commands"))

        let room = try #require(try await session.snapshot().room(Fix.roomID))
        #expect(room.revision == 4)
        #expect(room.claims.map(\.memberID) == [Fix.guest])
        #expect(session.pendingItemIDs.isEmpty)
        if case .synced = session.syncState {} else { Issue.record("Expected synced, got \(session.syncState)") }
    }

    @Test func previewIsPendingUntilTheServerAnswersAndAConflictRemovesIt() async throws {
        let gate = Gate()
        let latest = Fix.room(revision: 4, claims: [Fix.claim(Fix.fries, by: Fix.host)])
        let transport = ScriptedTransport { request, _ in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            await gate.wait()
            return (409, Fix.errorBody("revision_conflict", room: latest, currentRevision: 4))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()

        let attempt = Task { try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine)) }
        try await waitUntil { session.pendingItemIDs.contains(Fix.fries) }
        // The preview is visible, marked pending, and the room still reports the server's revision.
        let preview = try #require(try await session.snapshot().room(Fix.roomID))
        #expect(preview.claims.map(\.memberID) == [Fix.guest])
        #expect(preview.revision == 3)
        if case .sending = session.syncState {} else { Issue.record("Expected sending, got \(session.syncState)") }

        await gate.open()
        await #expect(throws: LedgerError.remote(.conflict)) { try await attempt.value }
        let room = try #require(try await session.snapshot().room(Fix.roomID))
        #expect(room.revision == 4)
        #expect(room.claims.map(\.memberID) == [Fix.host], "The other person's claim wins; the preview is gone")
        #expect(session.pendingItemIDs.isEmpty)
        #expect(session.notice?.issue == .conflict)
    }

    @Test func retryAfterConflictResendsTheIntentOnTheLatestRevision() async throws {
        let transport = ScriptedTransport { request, count in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            // Someone else changed the same item first, so the claim isn't resent on its own.
            if count == 2 { return (409, Fix.errorBody("revision_conflict", room: Fix.room(revision: 5, claims: [Fix.claim(Fix.pizza, by: Fix.host)]), currentRevision: 5)) }
            return (200, Fix.commandBody(Fix.room(revision: 6, claims: [Fix.claim(Fix.pizza, by: Fix.guest)])))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        await #expect(throws: LedgerError.remote(.conflict)) {
            try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.pizza, .mine))
        }
        try await session.retryAfterConflict()
        let envelopes = await transport.envelopes
        #expect(envelopes.map(\.expectedRevision) == [3, 5])
        #expect(envelopes[0].idempotencyKey != envelopes[1].idempotencyKey, "A different request gets a different key")
        #expect(session.notice == nil)
    }

    @Test func ownQuickTapsAreRebasedInsteadOfConflicting() async throws {
        let transport = ScriptedTransport { request, count in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            let claims = count == 2 ? [Fix.claim(Fix.fries, by: Fix.guest)] : [Fix.claim(Fix.fries, by: Fix.guest), Fix.claim(Fix.pizza, by: Fix.guest)]
            return (200, Fix.commandBody(Fix.room(revision: count == 2 ? 4 : 5, claims: claims)))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        // Both taps are built from the same on-screen revision, as quick taps are.
        async let first: Void = { _ = try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine)) }()
        async let second: Void = { _ = try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.pizza, .mine)) }()
        _ = try await (first, second)
        #expect(await transport.envelopes.map(\.expectedRevision) == [3, 4])
        #expect(try await session.snapshot().room(Fix.roomID)?.claims.count == 2)
    }

    @Test func offlineChangeIsUnsentAndResendingReusesItsKey() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            throw URLError(.notConnectedToInternet)
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        await #expect(throws: LedgerError.remote(.offline)) {
            try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine))
        }
        // Automatic retries (outcome unknown) reuse the exact same request.
        let attempts = await transport.envelopes
        #expect(attempts.count == 3)
        #expect(Set(attempts.map(\.idempotencyKey)).count == 1)
        #expect(session.unsent != nil)
        if case .offline = session.syncState {} else { Issue.record("Expected offline, got \(session.syncState)") }
        #expect(try await session.snapshot().room(Fix.roomID)?.claims.isEmpty == true, "Nothing looks confirmed")

        await transport.respond { _, _ in (200, Fix.commandBody(Fix.room(revision: 4, claims: [Fix.claim(Fix.fries, by: Fix.guest)]), replayed: true)) }
        try await session.resendUnsent()
        let all = await transport.envelopes
        #expect(all.last?.idempotencyKey == attempts[0].idempotencyKey)
        #expect(session.unsent == nil)
        #expect(try await session.snapshot().room(Fix.roomID)?.claims.count == 1)
    }

    @Test func endedAccessStopsTheSessionAndExplains() async throws {
        let transport = ScriptedTransport { _, _ in (401, Fix.errorBody("credential_expired")) }
        let session = Fix.session(transport)
        await #expect(throws: LedgerError.remote(.accessEnded)) { try await session.refresh() }
        #expect(session.syncState == .accessEnded)
        session.startPolling()
        #expect(!session.isPolling, "Polling never starts once access has ended")
    }

    @Test func pollingRefreshesUntilTheRoomIsFinished() async throws {
        let transport = ScriptedTransport { _, count in
            (200, Fix.roomBody(Fix.room(revision: count, state: count >= 3 ? "cancelled" : "open")))
        }
        let session = Fix.session(transport)
        session.pollInterval = .milliseconds(20)
        session.startPolling()
        try await waitUntil { !session.isPolling }
        #expect(await transport.requests.count == 3, "Stops after the terminal state is shown")
        #expect(try await session.snapshot().room(Fix.roomID)?.state == .cancelled)
    }

    @Test func serverRefusalsBecomeTheAppsOwnMessages() async throws {
        let taken = Fix.room(revision: 3, claims: [Fix.claim(Fix.fries, by: Fix.host)])
        let transport = ScriptedTransport { request, _ in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(taken)) }
            return (409, Fix.errorBody("item_already_claimed"))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        await #expect(throws: LedgerError.receipt(.itemAlreadyClaimed(by: Fix.host))) {
            try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine))
        }
    }

    @Test func localOnlyCommandsAreRefusedWithoutAnyRequest() async throws {
        let transport = ScriptedTransport { _, _ in (200, Fix.roomBody(Fix.room(revision: 3))) }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        await #expect(throws: LedgerError.self) {
            try await session.run(.setParticipants(Fix.roomID, expectedRevision: 3, participants: [Fix.host]))
        }
        #expect(await transport.envelopes.isEmpty)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

@MainActor @Suite("Remote mapping and links")
struct RemoteMappingTests {
    typealias Fix = RemoteFixtures

    @Test func invitationLinks() {
        let token = String(repeating: "A", count: 43)
        let configuration = Fix.configuration
        #expect(InvitationLink.token(from: URL(string: "https://squareup.example/r/\(token)")!, configuration: configuration) == token)
        #expect(InvitationLink.token(from: URL(string: "https://elsewhere.example/r/\(token)")!, configuration: configuration) == nil)
        #expect(InvitationLink.token(from: URL(string: "squp://join/\(token)")!, configuration: nil) == token)
        #expect(InvitationLink.token(from: URL(string: "https://squareup.example/r/short")!, configuration: configuration) == nil)
        #expect(InvitationLink.token(from: URL(string: "https://squareup.example/r/\(token)/extra")!, configuration: configuration) == nil)
        #expect(InvitationLink.token(fromText: "  \(token)\n", configuration: nil) == token)
        #expect(InvitationLink.token(fromText: "../../etc/passwd", configuration: nil) == nil)
        #expect(InvitationLink.appURL(token: token).absoluteString == "squp://join/\(token)")
    }

    @Test func configurationNeverAllowsInsecureOrIncompleteProduction() {
        #expect(RemoteConfiguration.make(scheme: "http", host: "example.com", authMode: "firebase", firebaseAPIKey: "k") == nil)
        #expect(RemoteConfiguration.make(scheme: "https", host: "example.com", authMode: "firebase", firebaseAPIKey: nil) == nil)
        #expect(RemoteConfiguration.make(scheme: "https", host: nil, authMode: nil, firebaseAPIKey: "k") == nil)
        #expect(RemoteConfiguration.make(scheme: "https", host: "example.com/path", authMode: nil, firebaseAPIKey: "k") == nil)
        #expect(RemoteConfiguration.fromBundle([:]) == nil)
        #expect(RemoteConfiguration.fromBundle(["SquareUpAPIHost": "$(SQUAREUP_API_HOST)"]) == nil)
        #expect(RemoteConfiguration.make(scheme: "https", host: "example.com", authMode: "firebase", firebaseAPIKey: "k")?.baseURL.absoluteString
            == "https://example.com")
        #if DEBUG
        #expect(RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:8080", authMode: "development", firebaseAPIKey: nil)?.authMode == .development)
        #endif
    }

    @Test func serverSnapshotBecomesTheAppsRoom() {
        let dto = Fix.room(revision: 7, claims: [Fix.claim(Fix.fries, by: Fix.guest), Fix.claim(Fix.pizza, by: Fix.host, "equalShare"),
                                                 Fix.claim(Fix.pizza, by: Fix.guest, "equalShare")])
        let room = RemoteRoomMapper.room(dto, base: nil, groupID: GroupID())
        #expect(room.id == Fix.roomID && room.revision == 7 && room.state == .open)
        #expect(room.hostID == Fix.host && room.payerID == Fix.host)
        #expect(room.participantIDs == [Fix.host, Fix.guest])
        #expect(room.claims.map(\.mode) == [.full, .equalShare, .equalShare])
        #expect(room.receipt.total.value == Money(minorUnits: 2165, currency: .usd))
        #expect(room.receipt.items.map(\.amount.minorUnits) == [950, 1000])
        let workspace = RemoteRoomMapper.workspace(dto, room: room, local: nil, groupName: nil)
        #expect(workspace.members[Fix.guest]?.displayName == "Sam")
        // Readiness uses the room's participants as the group, like the server.
        let issues = ReceiptRoomReadiness.issues(for: room, in: workspace)
        #expect(!issues.contains { if case .participantNotInGroup = $0 { true } else { false } })
        #expect(!issues.contains(.groupMissing))
    }

    @Test func roomCommandsTranslateToServerCommands() throws {
        let room = Fix.roomID
        #expect(try RemoteRoomMapper.command(.unclaim(room, expectedRevision: 1, item: Fix.fries)).type == "unclaim")
        let split = try RemoteRoomMapper.command(.setItemSplit(room, expectedRevision: 1, item: Fix.fries,
                                                               .exact([Share(Fix.host, Money(minorUnits: 500)), Share(Fix.guest, Money(minorUnits: 450))])))
        #expect(split.payload["split"]?["kind"] == "exact")
        let dispute = try RemoteRoomMapper.command(.dispute(room, expectedRevision: 1, .charge(Fix.tax), note: "Not mine"))
        #expect(dispute.payload["target"] == ["kind": "charge", "id": .string(Fix.id(Fix.tax))])
        #expect(try RemoteRoomMapper.command(.transition(room, expectedRevision: 1, .requestFinalReview)).payload["move"] == "requestFinalReview")
        #expect(try RemoteRoomMapper.command(.finalize(room, expectedRevision: 1)).type == "finalize")
        #expect(throws: RemoteRoomMapper.Failure.unsupportedCommand) {
            try RemoteRoomMapper.command(.openRoom(room, expectedRevision: 1, participants: []))
        }
    }

    @Test func serverTimestampsWithMicroseconds() {
        let date = RemoteRoomMapper.timestamp("2026-09-25T12:00:00.250000Z")
        #expect(date?.timeIntervalSince1970 == 1_790_337_600.25)
        #expect(RemoteRoomMapper.timestamp("not a date") == nil)
        #expect(RemoteRoomMapper.day(RemoteRoomMapper.date(fromDay: "2026-09-24")!) == "2026-09-24")
    }

    @Test func guestsAreRemappedToTheMembersTheHostChose() {
        let dto = Fix.room(revision: 3, claims: [Fix.claim(Fix.fries, by: Fix.guest)])
        let maya = MemberID()
        let room = SharingService.remap(RemoteRoomMapper.room(dto, base: nil, groupID: GroupID()), links: [Fix.id(Fix.guest): maya], dropping: [])
        #expect(room.participantIDs == [Fix.host, maya])
        #expect(room.claims.map(\.memberID) == [maya])
    }
}
