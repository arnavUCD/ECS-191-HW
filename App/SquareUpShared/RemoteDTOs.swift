import Foundation

// Wire types for the `/v1` API (server/API.md). Amounts are integer minor units; identifiers are
// UUID strings; the server computes allocation, readiness, and finalization.

nonisolated struct RoomDTO: Codable, Hashable, Sendable {
    let roomId: String
    let revision: Int
    let state: String
    let hostParticipantId: String
    let payerId: String?
    let receipt: ReceiptDTO
    let participants: [ParticipantDTO]
    let participantOrder: [String]
    let claims: [ClaimDTO]
    let disputes: [DisputeDTO]
    let reviews: [ReviewDTO]
    let needsReview: [String]
    let payerAcceptsFullReceipt: Bool
    let allocation: AllocationDTO
    let finalization: FinalizationDTO?
    let assets: [AssetDTO]
    let viewer: ViewerDTO
    let updatedAt: String
    // Receipt split (October 2026). Absent from older servers.
    /// `group` (published from a group), `temporary` ("Split with people now"), or `groupReceipt`.
    var kind: String? = nil
    /// Participants whose current share isn't reviewed (the host must acknowledge them to finalize).
    var unreviewed: [String]? = nil
    /// Temporary rooms: the deadline for claiming (before finalization) or paying (after).
    var expiresAt: String? = nil
    /// Temporary rooms: when and why the room ended (`allSquare`, `cancelled`, `expired`).
    var closedAt: String? = nil
    var endReason: String? = nil
    /// Temporary rooms after finalization: the host sees every payment, anyone else only their own.
    var payments: [RoomPaymentDTO]? = nil
    /// Temporary rooms: how many payment methods the payer chose to show people who owe them.
    var paymentDestinationCount: Int? = nil

    var isTerminal: Bool { state == "finalized" || state == "cancelled" }
    var isTemporary: Bool { kind == "temporary" }
    var isGroupReceipt: Bool { kind == "groupReceipt" }
    /// Whether this room has ended for good: a temporary room that's square, cancelled, or expired,
    /// or any other room that was finalized or cancelled.
    var hasEnded: Bool { isTemporary ? closedAt != nil : isTerminal }
    func participant(_ id: String) -> ParticipantDTO? { participants.first { $0.id == id } }
    func payment(of participantID: String) -> RoomPaymentDTO? { payments?.first { $0.participantId == participantID } }
}

/// What one participant owes the payer of a finalized temporary room, and how paying it is going.
/// Square Up never moves money: the participant reports a payment made elsewhere and only the
/// payer confirms it.
nonisolated struct RoomPaymentDTO: Codable, Hashable, Sendable, Identifiable {
    nonisolated struct Attempt: Codable, Hashable, Sendable {
        nonisolated struct Step: Codable, Hashable, Sendable {
            let state: String
            let actorId: String
            let at: String
            let note: String?
        }

        let id: String
        let provider: String
        let destinationId: String?
        /// `reportedSent`, `confirmed`, `rejected`, `disputed`, or `cancelled` (the group payment states).
        let state: String
        let history: [Step]
        let externalReference: String?
        let amount: Int
    }

    let participantId: String
    let amount: Int
    /// `owed`, `reportedSent`, `disputed`, or `confirmed`.
    let state: String
    let attempts: [Attempt]
    var confirmedAt: String? = nil

    var id: String { participantId }
    var latest: Attempt? { attempts.last }
}

nonisolated struct ParticipantUnitsDTO: Codable, Hashable, Sendable {
    let participantId: String
    let units: Int
}

nonisolated struct DestinationValueDTO: Codable, Hashable, Sendable {
    /// phone | email | username | link | instructions
    let kind: String
    let value: String
}

nonisolated struct DestinationDTO: Codable, Hashable, Sendable {
    let id: String
    let provider: String
    let value: DestinationValueDTO
    let link: String?
    let label: String?
    let isEnabled: Bool
    let isPreferred: Bool
    let createdAt: String?
    let updatedAt: String?
}

/// The payer's chosen payment methods in a temporary room, shown only to someone who still owes them.
nonisolated struct RoomDestinationsDTO: Codable, Hashable, Sendable {
    nonisolated struct Recipient: Codable, Hashable, Sendable {
        let participantId: String?
        let displayName: String
    }

    let recipient: Recipient
    let destinations: [DestinationDTO]
}

nonisolated struct ReceiptDTO: Codable, Hashable, Sendable {
    var merchant: String
    var date: String
    var currency: String
    var total: Int?
    var subtotal: Int?
    var items: [ItemDTO]
    var charges: [ChargeDTO]
}

nonisolated struct ItemDTO: Codable, Hashable, Sendable {
    let id: String
    var name: String
    var lineTotal: Int
    var quantity: Int?
    var unitPrice: Int?
    var isRefund: Bool
}

nonisolated struct ChargeDTO: Codable, Hashable, Sendable {
    let id: String
    var kind: String
    var label: String
    var amount: Int
    var allocation: AllocationRuleDTO
}

nonisolated struct ParticipantAmountDTO: Codable, Hashable, Sendable {
    let participantId: String
    let amount: Int
}

nonisolated struct ParticipantWeightDTO: Codable, Hashable, Sendable {
    let participantId: String
    let weight: Int
}

/// A charge allocation or an item split, depending on context.
nonisolated struct AllocationRuleDTO: Codable, Hashable, Sendable {
    var kind: String
    var members: [String]?
    var weights: [ParticipantWeightDTO]?
    var amounts: [ParticipantAmountDTO]?
    /// Item splits by the line's printed quantity.
    var units: [ParticipantUnitsDTO]? = nil
}

nonisolated struct ParticipantDTO: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// `host`, `member` (a seat from the host's group), or `guest`.
    let kind: String
    let joinedAt: String
    let removed: Bool
    let isClaimedSeat: Bool
    let accountBacked: Bool
}

nonisolated struct ClaimModeDTO: Codable, Hashable, Sendable {
    let kind: String
    var shares: Int?
    var amount: Int?
    /// `units`: how many of the line's printed quantity.
    var units: Int? = nil
}

nonisolated struct ClaimDTO: Codable, Hashable, Sendable {
    let itemId: String
    let participantId: String
    let mode: ClaimModeDTO
}

nonisolated struct DisputeTargetDTO: Codable, Hashable, Sendable {
    let kind: String
    let id: String
}

nonisolated struct DisputeDTO: Codable, Hashable, Sendable {
    let id: String
    let target: DisputeTargetDTO
    let raisedBy: String
    let note: String?
    let createdAt: String
    let status: String
    let resolvedBy: String?
    let resolvedAt: String?
    let resolutionNote: String?
}

nonisolated struct ReviewDTO: Codable, Hashable, Sendable {
    let participantId: String
    let revision: Int
}

nonisolated struct ItemShareDTO: Codable, Hashable, Sendable {
    let itemId: String
    let amount: Int
}

nonisolated struct ParticipantTotalDTO: Codable, Hashable, Sendable {
    let participantId: String
    let items: Int
    let tax: Int
    let tip: Int
    let fees: Int
    let discounts: Int
    let adjustments: Int
    let total: Int
    let itemShares: [ItemShareDTO]
}

nonisolated struct AllocationDTO: Codable, Hashable, Sendable {
    let receiptTotal: Int?
    let allocatedTotal: Int
    let remaining: Int?
    let isComplete: Bool
    let participants: [ParticipantTotalDTO]
}

nonisolated struct FinalizationDTO: Codable, Hashable, Sendable {
    let finalizedAt: String
    let finalizedBy: String
    let revision: Int
    let participants: [ParticipantTotalDTO]
    let payments: [ParticipantAmountDTO]
    let total: Int
    /// People whose share the host finalized without their review, after acknowledging each one.
    var hostResolved: [String]? = nil
}

nonisolated struct AssetDTO: Codable, Hashable, Sendable {
    let id: String
}

nonisolated struct AssetUploadDTO: Codable, Hashable, Sendable {
    let assetId: String
    let revision: Int
}

nonisolated struct ViewerDTO: Codable, Hashable, Sendable {
    let participantId: String
    let isHost: Bool
}

// MARK: - Requests and responses

nonisolated struct PublishRequest: Encodable, Sendable {
    nonisolated struct Person: Encodable, Sendable {
        let id: String
        let displayName: String
    }

    let roomId: String
    let hostParticipantId: String
    let payerId: String
    let participants: [Person]
    let receipt: ReceiptDTO
    let claims: [ClaimDTO]
    let payerAcceptsFullReceipt: Bool
    /// `temporary` for "Split with people now" (only the host, who paid); omitted for group rooms.
    var kind: String?
    /// Temporary rooms: which of the host's payment methods people who owe them will see.
    var paymentDestinationIds: [String]?
}

nonisolated struct PublishResponse: Decodable, Sendable {
    let room: RoomDTO
    let created: Bool
}

nonisolated struct RoomResponse: Decodable, Sendable {
    let room: RoomDTO
}

nonisolated struct CommandEnvelope: Codable, Hashable, Sendable {
    let commandId: String
    let idempotencyKey: String
    var expectedRevision: Int
    let type: String
    let payload: JSONValue

    init(type: String, payload: JSONValue, expectedRevision: Int) {
        commandId = UUID().uuidString.lowercased()
        idempotencyKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.expectedRevision = expectedRevision
        self.type = type
        self.payload = payload
    }

    /// The same intent against a newer revision. A new key: it is a different request.
    func rebased(to revision: Int) -> CommandEnvelope {
        CommandEnvelope(type: type, payload: payload, expectedRevision: revision)
    }
}

nonisolated struct CommandResponse: Decodable, Sendable {
    let commandId: String
    let applied: Bool
    let replayed: Bool
    let revision: Int
    let room: RoomDTO
}

nonisolated struct InvitationDTO: Codable, Hashable, Sendable, Identifiable {
    let invitationId: String
    let createdAt: String
    let expiresAt: String
    let revokedAt: String?
    let maxGuests: Int?
    let guestCount: Int
    /// Present only in the response that created it (the token is never stored by the server).
    let url: String?
    let token: String?
    /// The short code (`ABCD-EFGH-JKMN`), also only in the response that created it.
    var code: String? = nil

    var id: String { invitationId }
}

/// A short room code someone typed, with the identity to join as (`/v1/receipt-room-codes`). The
/// code travels in the body, never in a URL path.
nonisolated struct CodeRequest: Encodable, Sendable {
    let code: String
    var displayName: String?
    var seatId: String?
}

nonisolated struct InvitationOptions: Encodable, Sendable {
    var expiresInHours: Int?
    var maxGuests: Int?
    var revokeExisting = false
}

nonisolated struct InvitationResponse: Decodable, Sendable {
    let invitation: InvitationDTO
}

nonisolated struct InvitationListResponse: Decodable, Sendable {
    let invitations: [InvitationDTO]
}

nonisolated struct InvitationPreviewDTO: Decodable, Hashable, Sendable {
    nonisolated struct Host: Decodable, Hashable, Sendable {
        let displayName: String
    }

    nonisolated struct Seat: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let displayName: String
    }

    let status: String
    let roomState: String
    let expiresAt: String
    let host: Host
    let merchant: String
    let date: String
    let currency: String
    let openSeats: [Seat]
    let youAreParticipantId: String?
    /// `temporary` for "Split with people now" rooms. Absent from older servers.
    var kind: String? = nil
    /// The room has ended (square, cancelled, or expired): it takes nobody new.
    var ended: Bool? = nil
}

nonisolated struct InvitationPreviewResponse: Decodable, Sendable {
    let invitation: InvitationPreviewDTO
}

nonisolated struct JoinRequest: Encodable, Sendable {
    var displayName: String?
    var seatId: String?
}

nonisolated struct JoinResponse: Decodable, Sendable {
    let participantId: String
    let restored: Bool
    let credential: String?
    let credentialExpiresAt: String?
    let room: RoomDTO
}

nonisolated struct LinkGuestRequest: Encodable, Sendable {
    let guestToken: String
}

/// `{"error": {...}, "room": {...}?}`.
nonisolated struct ErrorEnvelope: Decodable, Sendable {
    nonisolated struct Body: Decodable, Sendable {
        let code: String
        let message: String
        let requestId: String?
        let currentRevision: Int?
        let retryAfterSeconds: Int?
        let cursor: Int?
        let owed: Int?
        let reason: String?
        let attemptIds: [String]?
        /// Unit claims: how many of the line are still unclaimed.
        let available: Int?
        /// Who hasn't reviewed their share (finalizing needs the host to acknowledge them).
        let participantIds: [String]?
    }

    let error: Body
    let room: RoomDTO?
}
