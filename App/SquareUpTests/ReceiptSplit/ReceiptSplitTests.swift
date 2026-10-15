import Foundation
@testable import SquareUp
import Testing

/// Receipt split (October 2026): unit claims ("2 of the 3"), the rule that re-dividing never drops
/// someone else's claim, invitation links and short codes (shared with the App Clip), temporary
/// rooms on the wire, the automatic resend of a claim a conflict didn't touch, and group receipts
/// travelling as group commands.
@MainActor @Suite("Receipt split")
struct ReceiptSplitTests {
    typealias Fix = RemoteFixtures

    // MARK: - Unit claims

    private static let maya = MemberID()
    private static let dev = MemberID()

    private static func beers(quantity: Int? = 3, total: Int64 = 1800) -> ReceiptLineItem {
        var item = ReceiptLineItem(name: .entered("Beer", by: maya, at: .now), lineTotal: .entered(Money(minorUnits: total, currency: .usd), by: maya, at: .now))
        item.quantity = quantity
        return item
    }

    private static func claim(_ item: ReceiptLineItem, _ member: MemberID, _ mode: ClaimMode) -> ReceiptClaim {
        ReceiptClaim(itemID: item.id, memberID: member, mode: mode, createdAt: .now, updatedAt: .now, revision: 1)
    }

    @Test func unitClaimsDivideByQuantityAndLeaveTheRestUnassigned() {
        let item = Self.beers()
        let order = [Self.maya, Self.dev]
        let partial = ReceiptAllocationEngine.allocate(item, claims: [Self.claim(item, Self.maya, .units(2))], participants: Set(order), order: order)
        #expect(partial.status == .partial(remaining: Money(minorUnits: 600, currency: .usd)))
        #expect(partial.shares == [Share(Self.maya, Money(minorUnits: 1200, currency: .usd))])
        let full = ReceiptAllocationEngine.allocate(item, claims: [Self.claim(item, Self.maya, .units(2)), Self.claim(item, Self.dev, .units(1))],
                                                    participants: Set(order), order: order)
        #expect(full.status == .allocated)
        #expect(full.shares.map(\.amount.minorUnits) == [1200, 600])
    }

    @Test func oddCentsGoByLargestRemainderAndAlwaysAddUp() {
        let item = Self.beers(quantity: 3, total: 1000)
        let order = [Self.maya, Self.dev]
        let result = ReceiptAllocationEngine.allocate(item, claims: [Self.claim(item, Self.maya, .units(1)), Self.claim(item, Self.dev, .units(2))],
                                                      participants: Set(order), order: order)
        #expect(result.shares.map(\.amount.minorUnits) == [333, 667])
        #expect(result.shares.map(\.amount.minorUnits).reduce(0, +) == 1000)
    }

    @Test func unitClaimsRefuseMixedModesMissingQuantityAndTooMany() {
        let order = [Self.maya, Self.dev]
        let item = Self.beers()
        let mixed = ReceiptAllocationEngine.allocate(item, claims: [Self.claim(item, Self.maya, .units(1)), Self.claim(item, Self.dev, .equalShare)],
                                                     participants: Set(order), order: order)
        #expect(mixed.status == .invalid(.mixedModes))
        let unknown = Self.beers(quantity: nil)
        #expect(ReceiptAllocationEngine.allocate(unknown, claims: [Self.claim(unknown, Self.maya, .units(1))], participants: Set(order), order: order)
            .status == .invalid(.noQuantity))
        let over = ReceiptAllocationEngine.allocate(item, claims: [Self.claim(item, Self.maya, .units(2)), Self.claim(item, Self.dev, .units(2))],
                                                    participants: Set(order), order: order)
        #expect(over.status == .invalid(.unitsExceed(1)))
        #expect(ReceiptAllocationEngine.preview(.units([MemberUnits(Self.maya, 4)]), of: item) == .failure(.tooManyUnits(1)))
        if case .success(let shares) = ReceiptAllocationEngine.preview(.units([MemberUnits(Self.maya, 1)]), of: item) {
            #expect(shares == [Share(Self.maya, Money(minorUnits: 600, currency: .usd))])
        } else {
            Issue.record("A partial unit split is a valid preview")
        }
    }

    // MARK: - Invitations and short codes (shared with the App Clip)

    @Test func linksAndCodesParseTheSameEverywhere() {
        let token = String(repeating: "Ab3_", count: 10) + "xyz"
        #expect(InvitationInput.parse("https://squareup.example/r/\(token)", expectedHost: "squareup.example") == .token(token))
        #expect(InvitationInput.parse("squp://join/\(token)", expectedHost: nil) == .token(token))
        #expect(InvitationInput.parse(token, expectedHost: nil) == .token(token))
        // Another host's link is never treated as an invitation.
        #expect(InvitationInput.parse("https://evil.example/r/\(token)", expectedHost: "squareup.example") == nil)
        // Codes: any case, spaces or dashes, the usual misreadings fixed (O→0, I/L→1).
        #expect(InvitationInput.parse("abcd-efgh-jkmn", expectedHost: nil) == .code("ABCDEFGHJKMN"))
        #expect(InvitationInput.parse(" ABCD EFGH JKMN ", expectedHost: nil) == .code("ABCDEFGHJKMN"))
        #expect(RoomCode.normalize("0OIL-1234-5678") == "0011" + "12345678")
        #expect(RoomCode.normalize("ABCD-EFGH-JKM") == nil)
        #expect(RoomCode.normalize("ABCD-EFGH-JKMU") == nil) // U isn't in the alphabet
        #expect(RoomCode.display("ABCDEFGHJKMN") == "ABCD-EFGH-JKMN")
        #expect(InvitationLink.token(from: InvitationLink.appURL(token: token), expectedHost: nil) == token)
    }

    @Test func theFullAppReadsInvitationsItsServerMade() {
        let token = String(repeating: "Zz9-", count: 11)
        let configuration = Fix.configuration
        #expect(InvitationLink.token(from: URL(string: "https://squareup.example/r/\(token)")!, configuration: configuration) == token)
        #expect(InvitationLink.token(fromText: "https://other.example/r/\(token)", configuration: configuration) == nil)
        #expect(InvitationLink.token(fromText: token, configuration: configuration) == token)
    }

    // MARK: - Temporary rooms on the wire

    @Test func temporaryRoomFieldsDecodeAndOlderRoomsStillDo() throws {
        var room = Fix.room(revision: 7, state: "finalized", viewer: Fix.guest)
        room.kind = "temporary"
        room.unreviewed = [Fix.id(Fix.guest)]
        room.expiresAt = "2026-10-20T12:00:00.000000Z"
        room.payments = [RoomPaymentDTO(participantId: Fix.id(Fix.guest), amount: 1200, state: "reportedSent", attempts: [
            .init(id: UUID().uuidString.lowercased(), provider: "venmo", destinationId: nil, state: "reportedSent",
                  history: [.init(state: "reportedSent", actorId: Fix.id(Fix.guest), at: "2026-10-13T12:00:00.000000Z", note: nil)],
                  externalReference: nil, amount: 1200),
        ])]
        let decoded = try JSONDecoder().decode(RoomDTO.self, from: Fix.json(room))
        #expect(decoded.isTemporary && !decoded.hasEnded)
        #expect(decoded.payment(of: Fix.id(Fix.guest))?.latest?.provider == "venmo")
        // A room from a server before this release: no kind, no payments — a group room as before.
        let old = try JSONDecoder().decode(RoomDTO.self, from: Fix.json(Fix.room(revision: 1)))
        #expect(old.kind == nil && !old.isTemporary && old.payments == nil)
        room.closedAt = "2026-10-14T12:00:00.000000Z"
        room.endReason = "allSquare"
        #expect(room.hasEnded)
    }

    @Test func unitClaimsAndAcknowledgementsTravelAsTheServerExpects() throws {
        let units = try RemoteRoomMapper.command(.claimUnits(Fix.roomID, expectedRevision: 3, item: Fix.fries, units: 2))
        #expect(units.type == "claimUnits")
        #expect(units.payload == ["itemId": .string(Fix.id(Fix.fries)), "units": 2])
        let plain = try RemoteRoomMapper.command(.finalize(Fix.roomID, expectedRevision: 9))
        #expect(plain.payload == [:])
        let acknowledged = try RemoteRoomMapper.command(.finalize(Fix.roomID, expectedRevision: 9, acknowledging: [Fix.guest]))
        #expect(acknowledged.payload == ["acknowledgeUnreviewed": .array([.string(Fix.id(Fix.guest))])])
        #expect(RemoteRoomMapper.mode(ClaimModeDTO(kind: "units", units: 2), .usd) == .units(2))
        #expect(RemoteRoomMapper.mode(.units(3)) == ClaimModeDTO(kind: "units", units: 3))
        let split = RemoteRoomMapper.rule(ItemSplit.units([MemberUnits(Fix.guest, 2)]))
        #expect(split.kind == "units" && split.units == [ParticipantUnitsDTO(participantId: Fix.id(Fix.guest), units: 2)])
    }

    @Test func refusalsBecomeExplanations() {
        func refusal(_ code: String, available: Int? = nil, people: [String]? = nil) -> ServerRefusal {
            ServerRefusal(status: 409, code: code, message: code, currentRevision: nil, retryAfterSeconds: nil, room: nil, available: available,
                          participantIds: people)
        }
        #expect(LedgerError.from(refusal("units_unavailable", available: 1), command: nil, room: nil) == .receipt(.unitsUnavailable(available: 1)))
        #expect(LedgerError.from(refusal("unreviewed_shares", people: [Fix.id(Fix.guest)]), command: nil, room: nil)
            == .receipt(.unreviewedShares([Fix.guest])))
        #expect(LedgerError.from(refusal("cannot_remove_others"), command: nil, room: nil) == .receipt(.cannotRemoveOthers))
        #expect(LedgerError.from(refusal("room_closed"), command: nil, room: nil) == .receipt(.roomClosed))
    }

    // MARK: - Conflicts that don't touch the item are resent automatically

    @Test func aClaimOnAnUntouchedItemIsResentOnTheLatestRoom() async throws {
        // Someone else claimed pizza first; this person's claim on fries means the same on the new room.
        let latest = Fix.room(revision: 4, claims: [Fix.claim(Fix.pizza, by: Fix.host)])
        let confirmed = Fix.room(revision: 5, claims: [Fix.claim(Fix.pizza, by: Fix.host), Fix.claim(Fix.fries, by: Fix.guest)])
        let transport = ScriptedTransport { request, count in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            return count == 2 ? (409, Fix.errorBody("revision_conflict", room: latest, currentRevision: 4)) : (200, Fix.commandBody(confirmed))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine))
        let envelopes = await transport.envelopes
        #expect(envelopes.map(\.expectedRevision) == [3, 4])
        #expect(envelopes[0].idempotencyKey != envelopes[1].idempotencyKey) // a new request: the first was never applied
        #expect(session.notice == nil)
        #expect(try await session.snapshot().room(Fix.roomID)?.revision == 5)
    }

    @Test func aClaimOnAnItemThatChangedStopsWithAnExplanation() async throws {
        let latest = Fix.room(revision: 4, claims: [Fix.claim(Fix.fries, by: Fix.host)])
        let transport = ScriptedTransport { request, _ in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(Fix.room(revision: 3))) }
            return (409, Fix.errorBody("revision_conflict", room: latest, currentRevision: 4))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        await #expect(throws: LedgerError.remote(.conflict)) {
            try await session.run(.claim(Fix.roomID, expectedRevision: 3, item: Fix.fries, .mine))
        }
        #expect(await transport.envelopes.count == 1)
        #expect(session.notice?.issue == .conflict)
    }

    @Test func paymentStepsAreSentWithoutAPreviewAndRetriedOnANewerRoom() async throws {
        var finalized = Fix.room(revision: 6, state: "finalized")
        finalized.kind = "temporary"
        var reported = Fix.room(revision: 8, state: "finalized")
        reported.kind = "temporary"
        reported.payments = [RoomPaymentDTO(participantId: Fix.id(Fix.guest), amount: 1000, state: "reportedSent", attempts: [])]
        let newer = Fix.room(revision: 7, state: "finalized")
        let (start, done) = (finalized, reported)
        let transport = ScriptedTransport { request, count in
            if request.httpMethod == "GET" { return (200, Fix.roomBody(start)) }
            return count == 2 ? (409, Fix.errorBody("revision_conflict", room: newer, currentRevision: 7)) : (200, Fix.commandBody(done))
        }
        let session = Fix.session(transport)
        _ = try await session.snapshot()
        try await session.sendRemote("reportPayment", ["provider": "venmo"])
        let envelopes = await transport.envelopes
        #expect(envelopes.map(\.type) == ["reportPayment", "reportPayment"])
        #expect(envelopes.map(\.expectedRevision) == [6, 7])
        #expect(session.base?.payment(of: Fix.id(Fix.guest))?.state == "reportedSent")
    }

    // MARK: - Group receipts travel as group commands

    @Test func groupReceiptChangesKeepTheirIdentityAsGroupCommands() async throws {
        let receiptID = ReceiptRoomID()
        let room = Fix.room(revision: 2, viewer: Fix.guest)
        let snapshot = SharedFixtures.snapshot()
        let transport = ScriptedTransport { request, _ in
            if SharedFixtures.path(request).hasSuffix("/commands") {
                var response = GroupCommandResponse(commandId: "c", applied: true, replayed: false, revision: 4, cursor: 1, result: [:], changes: nil)
                response.receipt = GroupReceiptDTO(id: RemoteRoomMapper.id(receiptID), state: "open", hostMemberId: Fix.id(Fix.host), payerId: nil,
                                                   participantIds: [], merchant: "M", date: "2026-10-13", currency: "USD", total: 2165,
                                                   revision: 3, createdAt: nil, updatedAt: nil, expenseId: nil, unreviewedCount: 1,
                                                   viewerIsParticipant: true, room: Fix.room(revision: 3, viewer: Fix.guest))
                return (200, SharedFixtures.json(response))
            }
            return (200, SharedFixtures.json(GroupSnapshotResponse(snapshot: snapshot)))
        }
        let ledger = SharedFixtures.ledger(transport, initial: snapshot)
        let channel = GroupReceiptChannel(ledger: ledger, receiptID: receiptID)
        let envelope = CommandEnvelope(type: "claimUnits", payload: ["itemId": "x", "units": 2], expectedRevision: room.revision)
        let response = try await channel.command(envelope)
        #expect(response.room.revision == 3)
        let sent = try #require(await transport.requests.compactMap { SharedFixtures.body($0) }.last)
        #expect(sent["type"] == "receiptCommand")
        #expect(sent["idempotencyKey"] == .string(envelope.idempotencyKey))
        #expect(sent["payload"]?["type"] == "claimUnits")
        #expect(sent["payload"]?["expectedRevision"] == 2)
        #expect(sent["payload"]?["receiptId"] == .string(RemoteRoomMapper.id(receiptID)))

        let finalize = CommandEnvelope(type: "finalize", payload: ["acknowledgeUnreviewed": .array([.string(Fix.id(Fix.guest))])], expectedRevision: 9)
        _ = try await channel.command(finalize)
        let last = try #require(await transport.requests.compactMap { SharedFixtures.body($0) }.last)
        #expect(last["type"] == "finalizeReceipt")
        #expect(last["payload"]?["acknowledgeUnreviewed"] == .array([.string(Fix.id(Fix.guest))]))
    }

    @Test func aStaleGroupReceiptChangeReadsLikeARoomConflict() async throws {
        let snapshot = SharedFixtures.snapshot()
        let latest = Fix.room(revision: 5)
        let transport = ScriptedTransport { request, _ in
            if SharedFixtures.path(request).hasSuffix("/commands") { return (409, Fix.errorBody("receipt_conflict", room: latest)) }
            return (200, SharedFixtures.json(GroupSnapshotResponse(snapshot: snapshot)))
        }
        let channel = GroupReceiptChannel(ledger: SharedFixtures.ledger(transport, initial: snapshot), receiptID: ReceiptRoomID())
        do {
            _ = try await channel.command(CommandEnvelope(type: "claim", payload: [:], expectedRevision: 1))
            Issue.record("Expected a conflict")
        } catch {
            #expect(error.code == "revision_conflict")
            #expect(error.refusal?.room?.revision == 5)
        }
    }

    @Test func pendingReceiptsMergeFromChangePagesAndNeverTouchBalances() throws {
        let base = SharedFixtures.snapshot()
        var next = base
        let receipt = GroupReceiptDTO(id: UUID().uuidString.lowercased(), state: "open", hostMemberId: SharedFixtures.id(SharedFixtures.riley),
                                      payerId: nil, participantIds: [], merchant: "Driftwood", date: "2026-10-13", currency: "USD", total: 3000,
                                      revision: 1, createdAt: nil, updatedAt: nil, expenseId: nil, unreviewedCount: 0, viewerIsParticipant: false,
                                      room: nil)
        next.receipts = [receipt]
        let event = SharedFixtures.event(2, "receiptPosted", data: ["receiptId": .string(receipt.id)])
        next.events = base.events + [event]
        var changes = SharedFixtures.changes(from: base, to: GroupSnapshotDTO(
            schemaVersion: 1, serverTime: base.serverTime, revision: 4, cursor: 2, group: base.group, viewer: base.viewer, members: base.members,
            expenses: base.expenses, settlements: base.settlements, attempts: base.attempts, balances: base.balances, events: next.events,
            eventsComplete: true))
        changes.receipts = [receipt]
        let merged = try #require(SharedGroupMapper.applying(changes, to: base))
        #expect(merged.receipts?.map(\.id) == [receipt.id])
        #expect(merged.balances == base.balances)
        #expect(SharedGroupMapper.balancesAgree(try SharedGroupMapper.workspace(merged), server: merged.balances))
    }
}
