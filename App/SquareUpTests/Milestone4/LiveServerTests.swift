import Foundation
@testable import SquareUp
import Testing

/// Milestone 4 §14.3 "deployed test server": the real Swift network stack against a running
/// server. Opt-in — set `SQUAREUP_TEST_SERVER` (e.g. `http://127.0.0.1:8080` for a local server
/// with `SQUAREUP_ALLOW_DEV_AUTH=1`). Pass it to the test runner with
/// `TEST_RUNNER_SQUAREUP_TEST_SERVER=… xcodebuild test …`. Uses development identities only.
enum LiveServer {
    static var configuration: RemoteConfiguration? {
        guard let raw = ProcessInfo.processInfo.environment["SQUAREUP_TEST_SERVER"], let url = URL(string: raw), let host = url.host() else {
            return nil
        }
        return RemoteConfiguration.make(scheme: url.scheme, host: url.port.map { "\(host):\($0)" } ?? host, authMode: "development",
                                        firebaseAPIKey: nil)
    }
}

@MainActor
@Suite("Live server", .enabled(if: LiveServer.configuration != nil), .serialized)
struct LiveServerTests {
    let host = MemberID()
    let maya = MemberID()
    let groupID = GroupID()
    let roomID = ReceiptRoomID()
    let fries = ReceiptItemID()
    let pizza = ReceiptItemID()

    func client(_ name: String) -> RoomAPIClient {
        let configuration = LiveServer.configuration!
        let transport = URLSessionTransport()
        // A separate Keychain service per person: two development identities in one process.
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "live.\(name).\(UUID())"))
        return RoomAPIClient(configuration: configuration, transport: transport, account: account)
    }

    func localRoom() -> (ReceiptRoom, LedgerSnapshot) {
        let now = Date.now
        var receipt = ReceiptDraft.empty(pages: [], currency: .usd, date: now)
        receipt.merchant.value = "Fictional Diner"
        receipt.total.value = Money(minorUnits: 1950)
        receipt.items = [ReceiptLineItem(id: fries, name: ReceiptField("Fries"), lineTotal: ReceiptField(Money(minorUnits: 950))),
                         ReceiptLineItem(id: pizza, name: ReceiptField("Pizza"), lineTotal: ReceiptField(Money(minorUnits: 1000)))]
        var room = ReceiptRoom(id: roomID, groupID: groupID, hostID: host, receipt: receipt, createdAt: now)
        room.payerID = host
        room.state = .open
        room.participantIDs = [host, maya]
        let snapshot = LedgerSnapshot(currentUserID: host, members: [Member(id: host, displayName: "Riley"), Member(id: maya, displayName: "Maya")],
                                      groups: [], expenses: [], settlements: [], receiptRooms: [room])
        return (room, snapshot)
    }

    @Test func twoPeopleCollaborateThroughTheServer() async throws {
        let hostAPI = client("host")
        let mayaAPI = client("maya")
        let (room, snapshot) = localRoom()

        // Host publishes and invites; publishing again is idempotent.
        let published = try await hostAPI.publish(RemoteRoomMapper.publishRequest(for: room, in: snapshot))
        #expect(published.created)
        #expect(try await hostAPI.publish(RemoteRoomMapper.publishRequest(for: room, in: snapshot)).created == false)
        let invitation = try await hostAPI.createInvitation(room: RemoteRoomMapper.id(roomID), options: InvitationOptions())
        let token = try #require(invitation.token)
        #expect(invitation.url?.hasSuffix("/r/\(token)") == true)

        // Maya previews (no items revealed) and claims her seat.
        let preview = try await mayaAPI.preview(token: token, as: .account)
        #expect(preview.openSeats.map(\.id) == [RemoteRoomMapper.id(maya)])
        let joined = try await mayaAPI.join(token: token, JoinRequest(seatId: RemoteRoomMapper.id(maya)), as: .account)
        #expect(joined.participantId == RemoteRoomMapper.id(maya))
        #expect(joined.credential == nil, "Accounts don't get guest credentials")

        let hostSession = RemoteRoomLedger(roomID: roomID, caller: .account, api: hostAPI)
        let mayaSession = RemoteRoomLedger(roomID: roomID, caller: .account, api: mayaAPI)
        let hostView = try #require(try await hostSession.snapshot().room(roomID))
        #expect(try await mayaSession.snapshot().currentUserID == maya)

        // Maya claims fries; the host, still looking at the older revision, claims fries too.
        let mayaView = try #require(try await mayaSession.snapshot().room(roomID))
        try await mayaSession.run(.claim(roomID, expectedRevision: mayaView.revision, item: fries, .mine))
        await #expect(throws: LedgerError.remote(.conflict)) {
            try await hostSession.run(.claim(roomID, expectedRevision: hostView.revision, item: fries, .mine))
        }
        // The conflict brought the latest room: Maya's claim, nothing partial from the host.
        let afterConflict = try #require(try await hostSession.snapshot().room(roomID))
        #expect(afterConflict.claims.map(\.memberID) == [maya])
        // Retrying the same intent on the latest revision is refused by the rules, not by the revision.
        await #expect(throws: LedgerError.receipt(.itemAlreadyClaimed(by: maya))) { try await hostSession.retryAfterConflict() }

        try await hostSession.run(.claim(roomID, expectedRevision: afterConflict.revision, item: pizza, .mine))

        // Maya can't use host controls; the server decides, not the app.
        try await mayaSession.refresh()
        let latestForMaya = try #require(try await mayaSession.snapshot().room(roomID))
        await #expect(throws: LedgerError.receipt(.hostOnly)) {
            try await mayaSession.run(.transition(roomID, expectedRevision: latestForMaya.revision, .requestFinalReview))
        }

        // The host finalizes; a retried finalize is a no-op with the same result.
        let ready = try #require(try await hostSession.snapshot().room(roomID))
        try await hostSession.run(.transition(roomID, expectedRevision: ready.revision, .requestFinalReview))
        let reviewing = try #require(try await hostSession.snapshot().room(roomID))
        try await hostSession.run(.finalize(roomID, expectedRevision: reviewing.revision))
        try await hostSession.run(.finalize(roomID, expectedRevision: reviewing.revision))
        let finalization = try #require(hostSession.base?.finalization)
        #expect(finalization.total == 1950)
        let serverTotals = RemoteRoomMapper.totals(finalization.participants, .usd)
        #expect(serverTotals[maya] == Money(minorUnits: 950) && serverTotals[host] == Money(minorUnits: 1000))

        // Swift computes the same totals from the same room (parity, over the network).
        let finalRoom = try #require(try await hostSession.snapshot().room(roomID))
        let swiftTotals = Dictionary(ReceiptAllocationEngine.allocate(finalRoom).participants.map { ($0.memberID, $0.total) }, uniquingKeysWith: +)
        #expect(swiftTotals.filter { !$0.value.isZero } == serverTotals.filter { !$0.value.isZero })

        // Maya sees the final, read-only state.
        try await mayaSession.refresh()
        #expect(try await mayaSession.snapshot().room(roomID)?.state == .finalized)
        let finalForMaya = try #require(try await mayaSession.snapshot().room(roomID))
        await #expect(throws: LedgerError.receipt(.notAllowedInState(.finalized))) {
            try await mayaSession.run(.unclaim(roomID, expectedRevision: finalForMaya.revision, item: fries))
        }
    }

    @Test func revokedInvitationsStopWorkingAndRevealNothing() async throws {
        let hostAPI = client("host")
        let (room, snapshot) = localRoom()
        _ = try await hostAPI.publish(RemoteRoomMapper.publishRequest(for: room, in: snapshot))
        let invitation = try await hostAPI.createInvitation(room: RemoteRoomMapper.id(roomID), options: InvitationOptions())
        _ = try await hostAPI.revokeInvitation(invitation.invitationId, room: RemoteRoomMapper.id(roomID))
        do {
            _ = try await client("stranger").preview(token: invitation.token!, as: .anonymous)
            Issue.record("A revoked invitation still worked")
        } catch {
            #expect(error.code == "invitation_revoked")
            #expect(error.refusal?.room == nil)
        }
    }
}
