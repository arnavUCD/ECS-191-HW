import Foundation
import Observation
import OSLog

/// Shared Receipt Rooms for the full app (milestone 4 §4.3): publishing a local room, invitations,
/// joining someone else's room, live sessions, and — for the host — saving the authoritative
/// result into this device's ledger.
///
/// Group ledgers stay on each device. Only the room travels: when the host's shared room is
/// finalized, the host's device records the expense once (`adoptShared`), after the host has
/// said who each guest is in the group.
@Observable
final class SharingService {
    let configuration: RemoteConfiguration?
    let directory: SharedRoomDirectory
    private(set) var accountStatus: AccountSession.Status = .signedOut
    /// An invitation opened from a link, waiting to be shown (`JoinRoomView`).
    var pendingInvitation: PendingInvitation?
    /// A room just published from this device: its invitation opens when the sharing sheet closes.
    var inviteOnOpen: ReceiptRoomID?
    /// The sharing sheet on screen. Presented by the receipt flow's container, which outlives the
    /// switch from the local room to the live one (a sheet presented by the local room would not).
    var sheet: RoomSheet?

    nonisolated enum RoomSheet: Identifiable, Equatable, Sendable {
        case share(ReceiptRoomID)
        case invite(ReceiptRoomID)

        var id: String {
            switch self {
            case .share(let room): "share.\(room)"
            case .invite(let room): "invite.\(room)"
            }
        }
    }

    nonisolated struct PendingInvitation: Identifiable, Equatable, Sendable {
        let id = UUID()
        let key: InvitationKey

        init(token: String) { key = .token(token) }
        init(code: String) { key = .code(code) }
    }

    /// How someone was invited: the link's 256-bit token, or the room's short code typed by hand.
    nonisolated enum InvitationKey: Hashable, Sendable {
        case token(String)
        case code(String)
    }

    /// An invitation this host made on this iPhone. Its link and code are secrets returned once by
    /// the server, so they're kept in the Keychain to show again.
    nonisolated struct SavedInvitation: Codable, Hashable, Sendable, Identifiable {
        let invitationID: String
        let url: String?
        let code: String?
        var id: String { invitationID }
    }

    @ObservationIgnored let account: AccountSession?
    @ObservationIgnored let api: RoomAPIClient?
    @ObservationIgnored private let local: any LedgerStore
    /// Milestone 7: the ledger that holds a room's draft when its group is a shared group (rooms
    /// for local groups live in this iPhone's ledger). Set by `SharedGroupsService`'s owner.
    @ObservationIgnored var sharedLedgerForRoom: (ReceiptRoomID) async -> SharedGroupLedger? = { _ in nil }
    @ObservationIgnored var sharedLedgerForGroup: (GroupID) -> SharedGroupLedger? = { _ in nil }

    func ledger(forRoom roomID: ReceiptRoomID) async -> any LedgerStore {
        await sharedLedgerForRoom(roomID) ?? local
    }

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var sessions: [ReceiptRoomID: RemoteRoomLedger] = [:]

    /// `account`: the device's one signed-in session (shared with shared groups); one is created when
    /// not given. `keychain`: where this account's own room secrets (invitation links) are kept.
    init(configuration: RemoteConfiguration?, local: any LedgerStore, directory: SharedRoomDirectory,
         transport: any HTTPTransport = URLSessionTransport(), keychain: KeychainStore = KeychainStore(), account sharedAccount: AccountSession? = nil) {
        self.configuration = configuration
        self.local = local
        self.directory = directory
        self.keychain = keychain
        if let configuration {
            let account = sharedAccount ?? AccountSession(configuration: configuration, transport: transport, keychain: keychain)
            self.account = account
            api = RoomAPIClient(configuration: configuration, transport: transport, account: account)
        } else {
            account = nil
            api = nil
        }
        Task { await refreshAccountStatus() }
    }

    var isConfigured: Bool { api != nil }

    /// Milestone 5: AI receipt processing through this build's server, with the same account.
    /// Uses its own session (long timeouts); `nil` when no server is configured.
    func receiptIntelligence() -> ReceiptIntelligenceAPI? {
        guard let configuration, let account else { return nil }
        return ReceiptIntelligenceAPI(configuration: configuration, transport: URLSessionTransport(session: ReceiptIntelligenceAPI.makeSession()),
                                      account: account)
    }

    // MARK: - Account

    func refreshAccountStatus() async {
        accountStatus = await account?.status ?? .signedOut
    }

    func addEmail(_ email: String, password: String) async throws(LedgerError) {
        try await accountCall { try await $0.addEmail(email, password: password) }
    }

    func signIn(email: String, password: String) async throws(LedgerError) {
        try await accountCall { try await $0.signIn(email: email, password: password) }
        sessions.removeAll()
    }

    /// Stops every room session (closing this account's local space). The account stays signed in.
    func close() {
        sessions.values.forEach { $0.stopPolling() }
        sessions.removeAll()
    }

    func signOut() async {
        await account?.signOut()
        sessions.values.forEach { $0.stopPolling() }
        sessions.removeAll()
        await refreshAccountStatus()
    }

    private func accountCall(_ body: (AccountSession) async throws -> Void) async throws(LedgerError) {
        guard let account else { throw .remote(.notConfigured) }
        do {
            try await body(account)
        } catch let failure as AccountSession.Failure {
            throw .remote(.signInFailed(failure))
        } catch {
            throw .remote(.unavailable)
        }
        await refreshAccountStatus()
    }

    // MARK: - Publishing (host)

    func isShared(_ id: ReceiptRoomID) -> Bool { directory.record(id) != nil }

    /// This device's own ledger (shared-room screens run on the room's session instead).
    func localSnapshot() async throws -> LedgerSnapshot { try await local.snapshot() }

    /// Publishes a local room that is open for claims. Publishing again is harmless.
    @discardableResult
    func publish(_ roomID: ReceiptRoomID) async throws(LedgerError) -> RoomDTO {
        guard let api else { throw .remote(.notConfigured) }
        let snapshot: LedgerSnapshot
        do {
            snapshot = try await ledger(forRoom: roomID).snapshot()
        } catch {
            throw error as? LedgerError ?? .unavailable
        }
        guard let room = snapshot.room(roomID) else { throw .receipt(.roomNotFound) }
        guard room.hostID == snapshot.currentUserID else { throw .receipt(.hostOnly) }
        guard room.state == .open || room.state == .resolving else { throw .receipt(.notAllowedInState(room.state)) }
        let request: PublishRequest
        do {
            request = try RemoteRoomMapper.publishRequest(for: room, in: snapshot)
        } catch {
            throw .receipt(.receiptNotReady([]))
        }
        let response: PublishResponse
        do {
            response = try await api.publish(request)
        } catch {
            throw LedgerError.from(error)
        }
        directory.upsert(roomID) { record in
            record.state = ReceiptRoomState(rawValue: response.room.state) ?? .open
            record.revision = response.room.revision
            record.updatedAt = .now
        } creating: {
            SharedRoomDirectory.Record(roomID: roomID, role: .host, title: room.title, state: .open, revision: response.room.revision,
                                       updatedAt: .now, groupID: room.groupID)
        }
        await refreshAccountStatus()
        Log.sync.info("Published a room (\(response.created ? "new" : "existing", privacy: .public))")
        return response.room
    }

    // MARK: - Live sessions

    /// The live session for a shared room this device hosts or joined (kept while the app runs,
    /// so returning to the room is instant).
    func session(for roomID: ReceiptRoomID) -> RemoteRoomLedger? {
        if let existing = sessions[roomID] { return existing }
        guard let api, let record = directory.record(roomID) else { return nil }
        let isHost = record.role == .host
        let hooks = RemoteRoomLedger.Hooks(
            local: { [weak self] in await self?.localContext(roomID, isHost: isHost) ?? RemoteRoomLedger.Local() },
            didChange: { [weak self] room in await self?.roomDidChange(room) },
            finalizeBlocker: { [weak self] room in
                guard let self, isHost, !room.isTemporary, !self.guestsNeedingMatch(in: room).isEmpty else { return nil }
                return .guestsNeedMatching
            }
        )
        let session = RemoteRoomLedger(roomID: roomID, caller: .account, api: api, hooks: hooks)
        sessions[roomID] = session
        return session
    }

    private func localContext(_ roomID: ReceiptRoomID, isHost: Bool) async -> RemoteRoomLedger.Local {
        guard isHost else { return RemoteRoomLedger.Local() }
        return await localDraftContext(roomID)
    }

    /// The host's own copy of a shared receipt on this iPhone — the draft it started from, with the
    /// photo and recognized text that never leave this iPhone unless the host shares the photo.
    /// Empty for anyone else (they never had a draft).
    func localDraftContext(_ roomID: ReceiptRoomID) async -> RemoteRoomLedger.Local {
        guard let snapshot = try? await ledger(forRoom: roomID).snapshot(), let room = snapshot.room(roomID) else {
            return RemoteRoomLedger.Local()
        }
        return RemoteRoomLedger.Local(snapshot: snapshot, room: room, groupName: room.groupID.flatMap(snapshot.group)?.name,
                                      finalExpenseID: room.finalExpenseID)
    }

    private func roomDidChange(_ room: RoomDTO) async -> ExpenseID? {
        guard let id = ReceiptRoomID(string: room.roomId) else { return nil }
        let state = ReceiptRoomState(rawValue: room.state) ?? .open
        directory.update(id) { record in
            record.state = state
            record.revision = room.revision
            record.updatedAt = .now
            record.title = room.receipt.merchant.isEmpty ? record.title : room.receipt.merchant
            if room.isTemporary { record.kind = "temporary"; record.endedAt = room.closedAt.flatMap(RemoteRoomMapper.timestamp) }
        }
        // A temporary room has no group: nothing is saved on this iPhone; it settles inside the room.
        guard directory.record(id)?.role == .host, state.isTerminal, !room.isTemporary else { return nil }
        return await adopt(room)
    }

    // MARK: - Saving the result on the host's device

    /// Guests the host still has to identify before the expense can be saved: anyone who joined
    /// through an invitation, has something assigned, and isn't matched to a group member.
    func guestsNeedingMatch(in room: RoomDTO) -> [ParticipantDTO] {
        guard !room.isTemporary, let id = ReceiptRoomID(string: room.roomId), let record = directory.record(id) else { return [] }
        let involved = Set(room.claims.map(\.participantId)).union(room.disputes.map(\.raisedBy))
            .union(room.allocation.participants.filter { $0.total != 0 }.map(\.participantId))
        return room.participants.filter { $0.kind == "guest" && !$0.removed && record.guestLinks[$0.id] == nil && involved.contains($0.id) }
    }

    func match(guest participantID: String, to memberID: MemberID, in roomID: ReceiptRoomID) {
        directory.update(roomID) { $0.guestLinks[participantID] = memberID }
    }

    func unmatch(guest participantID: String, in roomID: ReceiptRoomID) {
        directory.update(roomID) { $0.guestLinks[participantID] = nil }
    }

    /// Adds a guest to the host's group as a new member and matches them.
    func addGuestToGroup(_ guest: ParticipantDTO, roomID: ReceiptRoomID) async throws(LedgerError) {
        guard let groupID = directory.record(roomID)?.groupID else { throw .groupNotFound }
        let memberID: MemberID
        do {
            let store: any LedgerStore = sharedLedgerForGroup(groupID) ?? local
            memberID = try await store.addMember(MemberDraft(displayName: guest.displayName), to: groupID)
        } catch {
            throw error as? LedgerError ?? .unavailable
        }
        match(guest: guest.id, to: memberID, in: roomID)
    }

    /// Mirrors a finalized or cancelled shared room onto the host's local room, once.
    @discardableResult
    func adopt(_ dto: RoomDTO) async -> ExpenseID? {
        guard let id = ReceiptRoomID(string: dto.roomId), let record = directory.record(id), record.role == .host else { return nil }
        let store = await ledger(forRoom: id)
        guard let snapshot = try? await store.snapshot(), let localRoom = snapshot.room(id) else { return nil }
        if localRoom.state == .finalized || (localRoom.state == .cancelled && dto.state == "cancelled") {
            directory.update(id) { $0.adoptedState = localRoom.state; $0.adoptionProblem = nil }
            return localRoom.finalExpenseID
        }
        if dto.state == "finalized", !guestsNeedingMatch(in: dto).isEmpty {
            directory.update(id) { $0.adoptionProblem = .guestsNeedMatching }
            return nil
        }
        let links = record.guestLinks
        let shared = Self.remap(RemoteRoomMapper.room(dto, base: localRoom, groupID: localRoom.groupID ?? GroupID(id.rawValue)),
                                links: links, dropping: Set(dto.participants.filter { $0.kind == "guest" && links[$0.id] == nil }.map {
                                    RemoteRoomMapper.member($0.id)
                                }))
        let totals = dto.finalization.map { finalization in
            Dictionary(RemoteRoomMapper.totals(finalization.participants, CurrencyCode(dto.receipt.currency)).map { (links[RemoteRoomMapper.id($0.key)] ?? $0.key, $0.value) },
                       uniquingKeysWith: +)
        }
        // Milestone 7: in a shared group, the server records the finalized room as the group's
        // expense itself (from its own allocation), exactly once.
        if let sharedLedger = store as? SharedGroupLedger, dto.state == "finalized" {
            do {
                let expenseID = try await sharedLedger.adoptRemoteRoom(id, guestLinks: links)
                directory.update(id) { $0.adoptedState = .finalized; $0.adoptionProblem = nil }
                return expenseID
            } catch {
                Log.sync.error("Couldn't save the shared room to its shared group: \(String(describing: error), privacy: .public)")
                directory.update(id) { $0.adoptionProblem = .unavailable }
                return nil
            }
        }
        do {
            let result = try await store.run(.adoptShared(id, room: shared, finalTotals: totals))
            directory.update(id) { $0.adoptedState = ReceiptRoomState(rawValue: dto.state); $0.adoptionProblem = nil }
            Log.sync.info("Saved the shared room's \(dto.state, privacy: .public) state on this device")
            return result.expenseID
        } catch LedgerError.receipt(.sharedTotalsDiffer) {
            directory.update(id) { $0.adoptionProblem = .totalsDiffer }
        } catch {
            Log.sync.error("Couldn't save the shared room's result: \(String(describing: error), privacy: .public)")
            directory.update(id) { $0.adoptionProblem = .unavailable }
        }
        return nil
    }

    /// Replaces guest participant IDs with the group members the host matched them to, and drops
    /// unmatched guests who have nothing assigned.
    static func remap(_ room: ReceiptRoom, links: [String: MemberID], dropping: Set<MemberID>) -> ReceiptRoom {
        let map = Dictionary(links.map { (RemoteRoomMapper.member($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        func id(_ member: MemberID) -> MemberID { map[member] ?? member }
        var room = room
        room.payerID = room.payerID.map(id)
        room.participantIDs = room.participantIDs.filter { !dropping.contains($0) || map[$0] != nil }.map(id)
        room.claims = room.claims.map { ReceiptClaim(itemID: $0.itemID, memberID: id($0.memberID), mode: $0.mode, createdAt: $0.createdAt,
                                                     updatedAt: $0.updatedAt, revision: $0.revision) }
        room.disputes = room.disputes.map {
            ReceiptDispute(id: $0.id, target: $0.target, raisedBy: id($0.raisedBy), note: $0.note, createdAt: $0.createdAt, status: $0.status,
                           resolvedBy: $0.resolvedBy.map(id), resolvedAt: $0.resolvedAt, resolutionNote: $0.resolutionNote)
        }
        room.reviews = room.reviews.map { ReviewMark(memberID: id($0.memberID), revision: $0.revision) }
        room.needsReview = room.needsReview.map(id)
        for index in room.receipt.charges.indices {
            room.receipt.charges[index].allocation = switch room.receipt.charges[index].allocation {
            case .proportional: .proportional
            case .payer: .payer
            case .equal(let members): .equal(members?.map(id))
            case .shares(let weights): .shares(weights.map { MemberWeight(id($0.memberID), $0.weight) })
            case .exact(let shares): .exact(shares.map { Share(id($0.memberID), $0.amount) })
            }
        }
        return room
    }

    // MARK: - Invitations (host)

    /// Makes an invitation: a link, a QR code of it, and a short code. Each call makes another one
    /// (several can be active at once); `revokeExisting` turns the earlier ones off first.
    func createInvitation(for roomID: ReceiptRoomID, revokeExisting: Bool = false, maxGuests: Int? = nil) async throws(LedgerError) -> InvitationDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            let invitation = try await api.createInvitation(room: RemoteRoomMapper.id(roomID),
                                                            options: InvitationOptions(maxGuests: maxGuests, revokeExisting: revokeExisting))
            // The link and code are returned once; keep them (credentials) in the Keychain to show again.
            var saved = revokeExisting ? [] : savedInvitations(for: roomID)
            saved.removeAll { $0.invitationID == invitation.invitationId }
            saved.append(SavedInvitation(invitationID: invitation.invitationId, url: invitation.url, code: invitation.code))
            saveInvitations(saved, for: roomID)
            keychain.set(invitation.url, for: Self.invitationKey(roomID))
            return invitation
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// Turns off one invitation; people who already joined stay in the room.
    func revokeInvitation(_ invitationID: String, in roomID: ReceiptRoomID) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            _ = try await api.revokeInvitation(invitationID, room: RemoteRoomMapper.id(roomID))
            saveInvitations(savedInvitations(for: roomID).filter { $0.invitationID != invitationID }, for: roomID)
        } catch {
            throw LedgerError.from(error)
        }
    }

    func savedInvitations(for roomID: ReceiptRoomID) -> [SavedInvitation] {
        guard let text = keychain.string(for: Self.invitationsKey(roomID)), let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SavedInvitation].self, from: data)) ?? []
    }

    private func saveInvitations(_ invitations: [SavedInvitation], for roomID: ReceiptRoomID) {
        guard !invitations.isEmpty, let data = try? JSONEncoder().encode(invitations) else {
            keychain.remove(Self.invitationsKey(roomID))
            return
        }
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        keychain.set(text, for: Self.invitationsKey(roomID))
    }

    private static func invitationsKey(_ roomID: ReceiptRoomID) -> String { "invitations.\(RemoteRoomMapper.id(roomID))" }

    func invitations(for roomID: ReceiptRoomID) async throws(LedgerError) -> [InvitationDTO] {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.invitations(room: RemoteRoomMapper.id(roomID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// Revokes every active invitation; the room stays open for people already in it.
    func revokeInvitations(for roomID: ReceiptRoomID) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            for invitation in try await api.invitations(room: RemoteRoomMapper.id(roomID)) where invitation.revokedAt == nil {
                _ = try await api.revokeInvitation(invitation.invitationId, room: RemoteRoomMapper.id(roomID))
            }
            keychain.remove(Self.invitationKey(roomID))
            keychain.remove(Self.invitationsKey(roomID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    func savedInvitationURL(for roomID: ReceiptRoomID) -> URL? {
        keychain.string(for: Self.invitationKey(roomID)).flatMap(URL.init(string:))
    }

    private static func invitationKey(_ roomID: ReceiptRoomID) -> String { "invitation.\(RemoteRoomMapper.id(roomID))" }

    // MARK: - Joining (participant)

    func token(from url: URL) -> String? { InvitationLink.token(from: url, configuration: configuration) }

    func preview(_ token: String) async throws(LedgerError) -> InvitationPreviewDTO {
        try await preview(.token(token))
    }

    /// What an invitation (link or short code) shows before joining.
    func preview(_ key: InvitationKey) async throws(LedgerError) -> InvitationPreviewDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            switch key {
            case .token(let token): return try await api.preview(token: token, as: .account)
            case .code(let code): return try await api.preview(code: code, as: .account)
            }
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// Joins (or returns to) a room with this account. Returns the room to open.
    func join(_ token: String, displayName: String?, seatID: String?) async throws(LedgerError) -> ReceiptRoomID {
        try await join(.token(token), displayName: displayName, seatID: seatID)
    }

    /// Joins by link or short code — the same room, the same rules, the same participant on a rejoin.
    func join(_ key: InvitationKey, displayName: String?, seatID: String?) async throws(LedgerError) -> ReceiptRoomID {
        guard let api else { throw .remote(.notConfigured) }
        let response: JoinResponse
        do {
            let body = JoinRequest(displayName: displayName, seatId: seatID)
            switch key {
            case .token(let token): response = try await api.join(token: token, body, as: .account)
            case .code(let code): response = try await api.join(code: code, body, as: .account)
            }
        } catch {
            throw LedgerError.from(error)
        }
        guard let id = ReceiptRoomID(string: response.room.roomId) else { throw .remote(.unavailable) }
        directory.upsert(id) { record in
            record.state = ReceiptRoomState(rawValue: response.room.state) ?? .open
            record.revision = response.room.revision
            record.updatedAt = .now
        } creating: {
            SharedRoomDirectory.Record(roomID: id, role: response.room.viewer.isHost ? .host : .participant, title: response.room.receipt.merchant,
                                       state: .open, revision: response.room.revision, updatedAt: .now)
        }
        await refreshAccountStatus()
        return id
    }

    /// Moves an App Clip guest identity onto this account (milestone 4 §13): same participant,
    /// same claims, no duplicate. The guest credential stops working afterwards.
    func linkGuest(credential: String, roomID: ReceiptRoomID) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        let room: RoomDTO
        do {
            room = try await api.linkGuest(room: RemoteRoomMapper.id(roomID), guestCredential: credential)
        } catch {
            throw LedgerError.from(error)
        }
        directory.upsert(roomID) {
            $0.updatedAt = .now
        } creating: {
            SharedRoomDirectory.Record(roomID: roomID, role: .participant, title: room.receipt.merchant,
                                       state: ReceiptRoomState(rawValue: room.state) ?? .open, revision: room.revision, updatedAt: .now)
        }
    }

    /// Forgets a finished room on this device (the server keeps its record).
    func forget(_ roomID: ReceiptRoomID) {
        sessions[roomID]?.stopPolling()
        sessions[roomID] = nil
        directory.remove(roomID)
    }
}

extension LedgerError {
    /// A transport or server error outside a room session.
    nonisolated static func from(_ error: RemoteError) -> LedgerError {
        switch error {
        case .notConfigured: .remote(.notConfigured)
        case .offline, .timedOut: .remote(.offline)
        case .account(let failure): .remote(.signInFailed(failure))
        case .unexpected: .remote(.unavailable)
        case .server(let refusal):
            switch refusal.code {
            case "invitation_expired", "invitation_revoked", "invitation_invalid", "credential_expired", "not_a_participant", "room_not_found":
                .remote(.accessEnded)
            case "room_finalized": .receipt(.notAllowedInState(.finalized))
            case "room_cancelled": .receipt(.notAllowedInState(.cancelled))
            case "host_only": .receipt(.hostOnly)
            case "email_not_verified": .remote(.emailNotVerified)
            default: .remote(.refused(refusal.message))
            }
        }
    }
}
