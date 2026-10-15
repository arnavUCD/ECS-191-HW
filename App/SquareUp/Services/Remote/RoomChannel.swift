import Foundation

/// Where a live receipt's state comes from and where its changes go. The room screens and
/// `RemoteRoomLedger` are the same for both kinds of shared receipt:
///
/// - `RoomAPIChannel`: a Live Receipt Room (`/v1/receipt-rooms`) — "Split with people now" and
///   rooms published from a group — with the account's credential or a room guest's.
/// - `GroupReceiptChannel`: a receipt posted into a shared group ("Add to a group"). Its changes are
///   group commands and its state arrives with the group's normal sync, so it needs no separate
///   realtime system and never involves invitations or guests.
protocol RoomChannel {
    /// The receipt as it is now.
    func room() async throws(RemoteError) -> RoomDTO
    /// Sends one change. Resending the same envelope must be safe (it's applied at most once).
    func command(_ envelope: CommandEnvelope) async throws(RemoteError) -> CommandResponse
}

/// A Live Receipt Room on `/v1/receipt-rooms`.
struct RoomAPIChannel: RoomChannel {
    let api: RoomAPIClient
    let roomID: ReceiptRoomID
    let caller: RemoteCaller

    func room() async throws(RemoteError) -> RoomDTO {
        try await api.room(RemoteRoomMapper.id(roomID), as: caller)
    }

    func command(_ envelope: CommandEnvelope) async throws(RemoteError) -> CommandResponse {
        try await api.command(envelope, room: RemoteRoomMapper.id(roomID), as: caller)
    }
}
