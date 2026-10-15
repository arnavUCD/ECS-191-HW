import Foundation
import OSLog

/// Receipts posted into a shared group for asynchronous allocation ("Add to a group"). Split from
/// `SharedGroupLedger.swift` for size; same type, same rules.
///
/// A host posts a reviewed receipt with the members who were there. Those members claim items on
/// their own devices whenever they like; the host resolves what's left and finalizes it into
/// exactly one itemized expense. There's no live room, invitation, code, or guest: every change is
/// a group command (idempotent, revisioned, authorized by membership on the server) and every
/// update arrives with the group's normal sync. Until it's finalized it never touches balances.
extension SharedGroupLedger {
    /// Receipts in this group as the server last sent them (pending, or finished in the last week).
    var groupReceipts: [GroupReceiptDTO] { base?.receipts ?? [] }
    var pendingReceipts: [GroupReceiptDTO] { groupReceipts.filter(\.isPending) }

    func groupReceipt(_ id: ReceiptRoomID) -> GroupReceiptDTO? { base?.receipt(SharedGroupMapper.id(id)) }

    /// Whether a draft on this iPhone was already posted to this group (it stays here, hidden, as
    /// the host's copy of the photo and the recognized text).
    func hasPosted(_ id: ReceiptRoomID) -> Bool { groupReceipt(id) != nil }

    /// Pending receipts waiting for this person: their review, or — for the host — finishing them.
    var receiptsNeedingYou: [GroupReceiptDTO] {
        guard let viewer = base?.viewer.memberId else { return [] }
        return pendingReceipts.filter { receipt in
            guard receipt.viewerIsParticipant else { return false }
            if receipt.hostMemberId == viewer { return true }
            return receipt.room?.unreviewed?.contains(viewer) ?? false
        }
    }

    // MARK: - Posting

    /// Posts a reviewed receipt with the members who were there. High-consequence and never
    /// queued: it needs the server's answer. The receipt keeps the draft's identifier, so posting
    /// again (a retry, another device) is harmless and the expense it becomes has the same ID.
    func postReceipt(_ room: ReceiptRoom, participants: [MemberID], payer: MemberID) async throws {
        guard let current = base else { throw LedgerError.remote(.unavailable) }
        if isArchived { throw LedgerError.remote(.refused(String(localized: "This group was archived."))) }
        let receipt = RemoteRoomMapper.receipt(room.receipt)
        let encoded = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(receipt))) ?? .null
        let payload: JSONValue = [
            "receiptId": .string(SharedGroupMapper.id(room.id)),
            "receipt": encoded,
            "participantIds": .array(participants.map { .string(SharedGroupMapper.id($0)) }),
            "payerId": .string(SharedGroupMapper.id(payer)),
        ]
        let envelope = GroupCommandEnvelope(type: "postReceipt", payload: payload, expectedRevision: current.revision, knownCursor: current.cursor)
        let wire = SharedGroupMapper.WireCommand(type: "postReceipt", payload: payload, isRevisionStrict: false, requiresLiveResponse: true)
        _ = try await enqueue {
            try await self.deliverAndAccept(envelope, wire: wire, command: nil, summary: String(localized: "Post \(room.title)"), local: nil,
                                            previewID: nil)
        }
        Log.sync.info("Posted a receipt to a shared group")
    }

    // MARK: - Live session

    /// The live session for one of this group's receipts: the same room screens, with the group as
    /// the channel. `local` is the host's own draft on this iPhone (photo and recognized text).
    func receiptSession(_ id: ReceiptRoomID, local: @escaping () async -> RemoteRoomLedger.Local = { RemoteRoomLedger.Local() }) -> RemoteRoomLedger {
        if let existing = receiptSessions[id] { return existing }
        let hooks = RemoteRoomLedger.Hooks(
            local: { [weak self] in
                var context = await local()
                // Finalized into the group's expense (same ID), on every member's device.
                if self?.groupReceipt(id)?.state == "finalized" { context.finalExpenseID = ExpenseID(id.rawValue) }
                context.groupName = self?.groupName
                return context
            },
            didChange: { [weak self] room in
                room.state == "finalized" && self != nil ? ExpenseID(id.rawValue) : nil
            }
        )
        let session = RemoteRoomLedger(roomID: id, channel: GroupReceiptChannel(ledger: self, receiptID: id), hooks: hooks, now: now)
        receiptSessions[id] = session
        return session
    }
}

/// A group receipt's changes travel as group commands; its state arrives with the group's sync.
struct GroupReceiptChannel: RoomChannel {
    let ledger: SharedGroupLedger
    let receiptID: ReceiptRoomID

    private var groupKey: String { SharedGroupMapper.id(ledger.groupID) }
    private var receiptKey: String { SharedGroupMapper.id(receiptID) }

    func room() async throws(RemoteError) -> RoomDTO {
        // The group's normal sync first (one change page carries the receipt); the receipt alone
        // only when this device's copy of the group doesn't have it.
        do {
            try await ledger.refresh()
        } catch LedgerError.remote(.offline) {
            throw .offline
        } catch LedgerError.remote(.removedFromGroup) {
            throw .server(Self.refusal(403, "not_a_member", String(localized: "You're no longer in this group.")))
        } catch {
            // Showing what this device has, if it has it.
        }
        if let room = ledger.base?.receipt(receiptKey)?.room { return room }
        let receipt = try await ledger.api.receipt(receiptKey, group: groupKey)
        guard let room = receipt.room else {
            throw .server(Self.refusal(403, "not_a_participant", String(localized: "Only the people on this receipt can see its details.")))
        }
        return room
    }

    func command(_ envelope: CommandEnvelope) async throws(RemoteError) -> CommandResponse {
        let type: String
        var payload: [String: JSONValue] = ["receiptId": .string(receiptKey)]
        switch envelope.type {
        case "finalize":
            type = "finalizeReceipt"
            payload["expectedRevision"] = .int(envelope.expectedRevision)
            payload["acknowledgeUnreviewed"] = envelope.payload["acknowledgeUnreviewed"] ?? .array([])
        case "cancel":
            type = "cancelReceipt"
        default:
            type = "receiptCommand"
            payload["type"] = .string(envelope.type)
            payload["payload"] = envelope.payload
            payload["expectedRevision"] = .int(envelope.expectedRevision)
        }
        let group = GroupCommandEnvelope(receiptChange: envelope, type: type, payload: .object(payload), knownCursor: ledger.base?.cursor)
        let response: GroupCommandResponse
        do {
            response = try await ledger.api.command(group, group: groupKey)
        } catch {
            if case .server(let refusal) = error, refusal.code == "receipt_conflict" {
                // The receipt changed first: the same handling as a room's stale revision.
                var conflict = refusal
                conflict = ServerRefusal(status: refusal.status, code: "revision_conflict", message: refusal.message,
                                         currentRevision: refusal.currentRevision, retryAfterSeconds: refusal.retryAfterSeconds, room: refusal.room)
                throw .server(conflict)
            }
            throw error
        }
        // The group itself moves on too (an expense appears when it's finalized).
        await ledger.accept(response)
        let room: RoomDTO
        if let fresh = response.receipt?.room {
            room = fresh
        } else {
            room = try await self.room()
        }
        return CommandResponse(commandId: response.commandId, applied: response.applied, replayed: response.replayed, revision: room.revision,
                               room: room)
    }

    static func refusal(_ status: Int, _ code: String, _ message: String) -> ServerRefusal {
        ServerRefusal(status: status, code: code, message: message, currentRevision: nil, retryAfterSeconds: nil, room: nil)
    }
}
