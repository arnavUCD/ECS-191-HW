import Foundation
import OSLog

extension SharingService {

    // MARK: - Temporary rooms ("Split with people now")

    /// Starts a temporary room from a reviewed draft on this iPhone: no group, this person hosts it
    /// and paid, and everyone else joins by invitation. Starting again (a retry) returns the same room.
    /// `destinationIDs`: the payment methods people who owe them will see after finalization.
    @discardableResult
    func startTemporaryRoom(_ roomID: ReceiptRoomID, destinationIDs: [String]) async throws(LedgerError) -> RoomDTO {
        guard let api else { throw .remote(.notConfigured) }
        let snapshot: LedgerSnapshot
        do {
            snapshot = try await ledger(forRoom: roomID).snapshot()
        } catch {
            throw error as? LedgerError ?? .unavailable
        }
        guard let room = snapshot.room(roomID) else { throw .receipt(.roomNotFound) }
        let reconciliation = ReceiptValidator.reconcile(room.receipt)
        guard reconciliation.canConfirm, room.receipt.total.value != nil else {
            throw .receipt(.receiptNotReady(reconciliation.blockingIssues.map(\.kind)))
        }
        let host = snapshot.currentUserID
        let name = String((snapshot.members[host]?.displayName ?? String(localized: "Host")).prefix(40))
        let request = PublishRequest(
            roomId: RemoteRoomMapper.id(roomID), hostParticipantId: RemoteRoomMapper.id(host), payerId: RemoteRoomMapper.id(host),
            participants: [PublishRequest.Person(id: RemoteRoomMapper.id(host), displayName: name)],
            receipt: RemoteRoomMapper.receipt(room.receipt), claims: [], payerAcceptsFullReceipt: false,
            kind: "temporary", paymentDestinationIds: destinationIDs
        )
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
            record.kind = "temporary"
        } creating: {
            SharedRoomDirectory.Record(roomID: roomID, role: .host, title: room.title, state: .open, revision: response.room.revision,
                                       updatedAt: .now, groupID: nil, kind: "temporary")
        }
        await refreshAccountStatus()
        Log.sync.info("Started a temporary room (\(response.created ? "new" : "existing", privacy: .public))")
        return response.room
    }

    /// Shares the receipt photo with the people in a room this person hosts (only when they choose
    /// to). The server keeps it private: only people in the room can see it, through the API.
    func shareReceiptPhoto(_ jpeg: Data, roomID: ReceiptRoomID) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            _ = try await api.uploadReceiptPhoto(jpeg, room: RemoteRoomMapper.id(roomID))
        } catch {
            throw LedgerError.from(error)
        }
    }

    func receiptPhoto(_ assetID: String, roomID: ReceiptRoomID) async throws(LedgerError) -> Data {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.receiptPhoto(assetID, room: RemoteRoomMapper.id(roomID), as: .account)
        } catch {
            throw LedgerError.from(error)
        }
    }

    /// The payer's chosen payment methods, shown only while this person owes them.
    func paymentDestinations(for roomID: ReceiptRoomID) async throws(LedgerError) -> RoomDestinationsDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.paymentDestinations(room: RemoteRoomMapper.id(roomID), as: .account)
        } catch {
            throw LedgerError.from(error)
        }
    }
}
