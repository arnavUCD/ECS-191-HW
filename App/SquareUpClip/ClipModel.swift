import Foundation
import Observation

/// The App Clip's one job: join a temporary room ("Split with people now") as a guest, claim what
/// you had, review your share, and — once the host finalizes — pay them back outside Square Up and
/// report it. Everything is decided by the server; this keeps the latest room, sends changes with
/// an idempotency key and the revision they were based on, and polls while the room is on screen.
@Observable
@MainActor
final class ClipModel {
    enum Phase: Equatable {
        /// Opened without an invitation: type the host's short code.
        case needsInvitation
        case loading
        /// What the invitation shows before joining (no items or amounts yet).
        case preview(InvitationPreviewDTO)
        case inRoom
        /// The invitation doesn't work, or this guest's access ended.
        case unavailable(String)
    }

    private(set) var phase: Phase = .needsInvitation
    private(set) var room: RoomDTO?
    private(set) var invitation: InvitationInput?
    private(set) var destinations: RoomDestinationsDTO?
    private(set) var isSending = false
    private(set) var isOffline = false
    private(set) var lastSynced: Date?
    var name = ""
    var message: String?

    @ObservationIgnored let configuration: ClipConfiguration?
    @ObservationIgnored private let client: ClipRoomClient?
    @ObservationIgnored private let credentials: ClipCredentials
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Counts invitations opened, so a slower return to the last room never replaces a newer one.
    @ObservationIgnored private var invocations = 0
    /// The last room's credential, when the preview showed this guest is already in the invited
    /// room: joining with it restores the same participant. Anyone else joins as someone new.
    @ObservationIgnored private var returningCredential: String?

    init(configuration: ClipConfiguration? = .current(), credentials: ClipCredentials = ClipCredentials()) {
        self.configuration = configuration
        client = configuration.map { ClipRoomClient(configuration: $0) }
        self.credentials = credentials
        if configuration == nil { phase = .unavailable(String(localized: "This build isn't connected to Square Up's server.")) }
    }

    var viewerID: String? { room?.viewer.participantId }
    private var credential: String? { room.flatMap { credentials.credential(for: $0.roomId) } }

    // MARK: Invocation

    /// An App Clip invocation (`https://<server>/r/<token>`), a link opened another way, or a
    /// code typed by hand — read exactly like the full app reads them.
    func handle(_ text: String) async {
        guard let configuration else { return }
        // The registered prefix (an App Clip experience or TestFlight URL) names no room.
        if configuration.isInvitationPrefix(text) { return }
        guard let found = configuration.invitation(in: text) else {
            message = String(localized: "That isn't a Square Up invitation. Check the code with the host.")
            return
        }
        invocations += 1
        stopPolling()
        invitation = found
        message = nil
        await loadPreview()
    }

    /// Back to typing a code (after an invitation that didn't work).
    func enterCode() {
        stopPolling()
        invitation = nil
        message = nil
        phase = .needsInvitation
    }

    /// Opening the clip again (from the App Switcher or a notification) returns to the last room —
    /// unless an invitation is being opened, which always wins.
    func resume() async {
        guard room == nil, invitation == nil, let roomID = credentials.lastRoomID, let credential = credentials.credential(for: roomID) else { return }
        await load(roomID, credential: credential)
    }

    private func loadPreview() async {
        guard let client, let invitation else { return }
        phase = .loading
        do {
            let preview = try await self.preview(invitation, client: client)
            if preview.youAreParticipantId != nil || preview.isClosed {
                // Already in it (or it ended): rejoining restores the same participant.
                phase = .preview(preview)
                if preview.youAreParticipantId != nil { await join() }
                return
            }
            phase = .preview(preview)
        } catch {
            phase = .unavailable(error.code == "offline" ? error.message : explanation(error))
        }
    }

    /// The preview, asked with the last room's guest credential so a guest coming back to that room
    /// is recognized. A credential whose room ended is forgotten, and the preview asked again
    /// without it: it must never stop someone joining a different room.
    private func preview(_ invitation: InvitationInput, client: ClipRoomClient) async throws(ClipError) -> InvitationPreviewDTO {
        returningCredential = nil
        guard let roomID = credentials.lastRoomID, let credential = credentials.credential(for: roomID) else {
            return try await client.preview(invitation, credential: nil)
        }
        let preview: InvitationPreviewDTO
        do {
            preview = try await client.preview(invitation, credential: credential)
        } catch {
            guard error.code == "credential_expired" else { throw error }
            credentials.remove(roomID)
            credentials.lastRoomID = nil
            return try await client.preview(invitation, credential: nil)
        }
        if preview.youAreParticipantId != nil { returningCredential = credential }
        return preview
    }

    func join() async {
        guard let client, let invitation else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        defer { isSending = false }
        do {
            let response = try await client.join(invitation, name: trimmed.isEmpty ? nil : String(trimmed.prefix(40)), credential: returningCredential)
            if let credential = response.credential { credentials.save(credential, for: response.room.roomId) }
            credentials.lastRoomID = response.room.roomId
            accept(response.room)
            phase = .inRoom
            startPolling()
        } catch {
            message = explanation(error)
            if error.endsAccess { phase = .unavailable(explanation(error)) }
        }
    }

    private func load(_ roomID: String, credential: String) async {
        guard let client else { return }
        let opened = invocations
        phase = .loading
        do {
            let latest = try await client.room(roomID, credential: credential)
            guard invocations == opened else { return } // an invitation opened meanwhile
            accept(latest)
            phase = .inRoom
            startPolling()
        } catch {
            guard invocations == opened else { return }
            if error.endsAccess {
                credentials.remove(roomID)
                credentials.lastRoomID = nil
                phase = .needsInvitation
            } else {
                phase = .unavailable(explanation(error))
            }
        }
    }

    // MARK: Sync

    func refresh() async {
        guard let client, let room, let credential else { return }
        do {
            let latest = try await client.room(room.roomId, credential: credential)
            guard self.room?.roomId == room.roomId else { return } // another room opened meanwhile
            accept(latest)
            isOffline = false
        } catch {
            guard self.room?.roomId == room.roomId else { return }
            isOffline = error.code == "offline"
            if error.endsAccess { endAccess(error) }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { break }
                if isSending { continue }
                await refresh()
                if room?.hasEnded == true { break }
            }
            self?.pollTask = nil
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The newest copy of the current room, or a different room after joining one. Revisions are
    /// only compared within the same room.
    private func accept(_ latest: RoomDTO) {
        if let room, room.roomId == latest.roomId, latest.revision < room.revision { return }
        if room?.roomId != latest.roomId { destinations = nil }
        room = latest
        lastSynced = .now
        if latest.state == "finalized", destinations == nil, latest.payment(of: latest.viewer.participantId).map({ $0.state != "confirmed" }) == true {
            Task { await loadDestinations() }
        }
    }

    private func endAccess(_ error: ClipError) {
        stopPolling()
        if let room { credentials.remove(room.roomId) }
        credentials.lastRoomID = nil
        phase = .unavailable(explanation(error))
    }

    func loadDestinations() async {
        guard let client, let room, let credential else { return }
        let found = try? await client.paymentDestinations(room: room.roomId, credential: credential)
        guard self.room?.roomId == room.roomId else { return }
        destinations = found
    }

    // MARK: Changes

    func claim(_ itemID: String, mine: Bool) async {
        await send("claim", ["itemId": .string(itemID), "request": mine ? "mine" : "share"], item: itemID)
    }

    func unclaim(_ itemID: String) async { await send("unclaim", ["itemId": .string(itemID)], item: itemID) }

    func claimUnits(_ itemID: String, units: Int) async {
        await send("claimUnits", ["itemId": .string(itemID), "units": .int(units)], item: itemID)
    }

    func markReviewed() async { await send("markReviewed", [:], item: nil) }

    func dispute(_ itemID: String, note: String?) async {
        var payload: [String: JSONValue] = ["target": ["kind": "item", "id": .string(itemID)]]
        if let note, !note.isEmpty { payload["note"] = .string(String(note.prefix(140))) }
        await send("dispute", .object(payload), item: nil)
    }

    func reportPayment(provider: String, destinationID: String?) async {
        var payload: [String: JSONValue] = ["provider": .string(provider)]
        if let destinationID { payload["destinationId"] = .string(destinationID) }
        await send("reportPayment", .object(payload), item: nil, isPayment: true)
    }

    func cancelPaymentReport() async { await send("cancelPaymentReport", [:], item: nil, isPayment: true) }

    /// Sends one change against the room it was based on. When someone else changed something
    /// unrelated first, it's sent again on the latest room; a change to the same item stops and
    /// explains, so nobody's claim is overwritten.
    private func send(_ type: String, _ payload: JSONValue, item: String?, isPayment: Bool = false) async {
        guard let client, let room, let credential else { return }
        isSending = true
        defer { isSending = false }
        var base = room
        for _ in 0..<3 {
            let envelope = CommandEnvelope(type: type, payload: payload, expectedRevision: base.revision)
            do {
                let latest = try await client.command(envelope, room: base.roomId, credential: credential).room
                guard self.room?.roomId == base.roomId else { return } // another room opened meanwhile
                accept(latest)
                message = nil
                isOffline = false
                return
            } catch {
                if error.code == "revision_conflict", let latest = error.room, isPayment || Self.unchanged(item, before: base, after: latest) {
                    accept(latest)
                    base = latest
                    continue
                }
                if let latest = error.room { accept(latest) }
                if error.endsAccess { endAccess(error); return }
                isOffline = error.code == "offline"
                message = explanation(error)
                return
            }
        }
    }

    static func unchanged(_ item: String?, before: RoomDTO, after: RoomDTO) -> Bool {
        guard let item else { return false }
        return before.state == after.state && Set(before.claims.filter { $0.itemId == item }) == Set(after.claims.filter { $0.itemId == item })
            && before.receipt.items.first { $0.id == item } == after.receipt.items.first { $0.id == item }
    }

    private func explanation(_ error: ClipError) -> String {
        switch error.code {
        case "invitation_expired": String(localized: "This invitation expired. Ask the host for a new code.")
        case "invitation_revoked": String(localized: "The host turned off this invitation. Ask for a new code.")
        case "invitation_invalid": String(localized: "That code or link doesn't work. Check it with the host.")
        case "credential_expired", "not_a_participant": String(localized: "Your place in this room ended. Ask the host for a new code.")
        case "room_closed", "room_expired": String(localized: "This room has ended.")
        case "item_already_claimed": String(localized: "Someone already claimed this. Share it, or dispute it if that's wrong.")
        case "rate_limited": String(localized: "Too many tries. Wait a moment and try again.")
        default: error.message
        }
    }
}

extension InvitationPreviewDTO {
    /// Not taking new people: finalized or cancelled, or the temporary room ended.
    var isClosed: Bool { roomState == "finalized" || roomState == "cancelled" || ended == true }
}
