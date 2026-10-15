import Foundation

// Wire types for shared groups (milestone 7; `server/API.md` "Shared groups"). Money is always
// integer minor units in the group's currency. Identifiers are UUID strings (lowercase from the
// server; any case accepted). Codable and Hashable so a confirmed snapshot can be cached exactly
// as the server sent it.

// MARK: - Account and profile

nonisolated struct AccountDTO: Codable, Hashable, Sendable {
    let recoverable: Bool
    /// Firebase reports the address as verified; shared groups need it. Absent from older servers.
    var emailVerified: Bool?
    let profile: ProfileDTO?
}

nonisolated struct AccountResponse: Codable, Sendable {
    let account: AccountDTO
}

nonisolated struct ProfileDTO: Codable, Hashable, Sendable {
    let memberId: String
    let displayName: String
    let locale: String?
    let currency: String?
    let destinations: [DestinationDTO]
    let createdAt: String
    let updatedAt: String
}

nonisolated struct ProfileResponse: Codable, Sendable {
    let profile: ProfileDTO
}

nonisolated struct ProfileRequest: Codable, Sendable {
    let displayName: String
    let locale: String?
    let currency: String?
    /// A fresh random ID proposed for a new profile; ignored once the profile exists.
    let memberId: String?
}

// `DestinationDTO` and `DestinationValueDTO` live in RemoteDTOs.swift (temporary rooms use them too).

nonisolated struct DestinationRequest: Codable, Sendable {
    let provider: String
    let value: DestinationValueDTO
    let link: String?
    let label: String?
    let isEnabled: Bool
    let isPreferred: Bool
}

nonisolated struct RevealedDestinationsDTO: Codable, Hashable, Sendable {
    let memberId: String
    let destinations: [DestinationDTO]
}

// MARK: - Groups

nonisolated struct GroupHeaderDTO: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let details: String?
    let symbol: String
    let currency: String
    let simplifiesDebts: Bool
    let ownerMemberId: String
    let createdAt: String
    let archivedAt: String?
    let revision: Int
    let publishedFromDevice: Bool?
}

nonisolated struct GroupViewerDTO: Codable, Hashable, Sendable {
    let memberId: String
    let isOwner: Bool
}

nonisolated struct GroupMemberDTO: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let handle: String?
    /// active | pending | removed
    let status: String
    let hasAccount: Bool
    let addedAt: String
    let joinedAt: String?
    let removedAt: String?
    let destinationProviders: [String]
}

nonisolated struct ShareDTO: Codable, Hashable, Sendable {
    let memberId: String
    let amount: Int
}

nonisolated struct ReceiptSnapshotDTO: Codable, Hashable, Sendable {
    nonisolated struct Item: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let quantity: Int?
        let lineTotal: Int
        let isRefund: Bool
        let shares: [ShareDTO]
    }

    nonisolated struct Charge: Codable, Hashable, Sendable {
        let id: String
        let kind: String
        let label: String
        let amount: Int
        let allocation: JSONValue
        let shares: [ShareDTO]
    }

    nonisolated struct Participant: Codable, Hashable, Sendable {
        let memberId: String
        let items: Int
        let tax: Int
        let tip: Int
        let fees: Int
        let discounts: Int
        let adjustments: Int
        let total: Int
    }

    nonisolated struct Rounding: Codable, Hashable, Sendable {
        let sourceKind: String
        let sourceId: String
        let memberId: String
        let amount: Int
    }

    let merchant: String
    let date: String
    let total: Int
    let items: [Item]
    let charges: [Charge]
    let participants: [Participant]
    let rounding: [Rounding]
}

nonisolated struct GroupExpenseDTO: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let merchant: String?
    let date: String
    let total: Int
    let category: String
    let splitMethod: String
    let payments: [ShareDTO]
    let allocations: [ShareDTO]
    let note: String?
    let createdBy: String
    let createdAt: String
    let revision: Int
    let updatedAt: String?
    let updatedBy: String?
    let deletedAt: String?
    let deletedBy: String?
    let receipt: ReceiptSnapshotDTO?
    let receiptOmitted: Bool?
    let roomId: String?
}

nonisolated struct GroupSettlementDTO: Codable, Hashable, Sendable {
    let id: String
    let fromId: String
    let toId: String
    let amount: Int
    let date: String
    let recordedBy: String
    let provider: String?
    let attemptId: String?
    let confirmedAt: String?
    let confirmedBy: String?
}

nonisolated struct AttemptTransitionDTO: Codable, Hashable, Sendable {
    let state: String
    let actorId: String
    let at: String
    let note: String?
}

nonisolated struct GroupAttemptDTO: Codable, Hashable, Sendable {
    let id: String
    let payerId: String
    let recipientId: String
    let destinationId: String?
    let provider: String
    let amount: Int
    let memo: String
    let state: String
    let history: [AttemptTransitionDTO]
    let externalReference: String?
    let settlementId: String?
}

nonisolated struct PlannedPaymentDTO: Codable, Hashable, Sendable {
    let payerId: String
    let recipientId: String
    let amount: Int
}

/// Balances the server derived from the authoritative records. The app recomputes them and
/// compares; a difference means the snapshot can't be trusted as mapped (`SharedGroupMapper`).
nonisolated struct GroupBalancesDTO: Codable, Hashable, Sendable {
    let simplified: Bool
    let payments: [PlannedPaymentDTO]
    let directPaymentCount: Int
    let simplifiedPaymentCount: Int
    let pendingAttemptIds: [String]
    let confirmedNets: [String: Int]
    let availableNets: [String: Int]
}

nonisolated struct GroupEventDTO: Codable, Hashable, Sendable {
    let id: String
    let sequence: Int
    let actorMemberId: String
    let at: String
    let kind: String
    let data: JSONValue
}

/// Everything one member may see of a group, at one revision.
nonisolated struct GroupSnapshotDTO: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let serverTime: String
    let revision: Int
    let cursor: Int
    var group: GroupHeaderDTO
    var viewer: GroupViewerDTO
    var members: [GroupMemberDTO]
    var expenses: [GroupExpenseDTO]
    var settlements: [GroupSettlementDTO]
    var attempts: [GroupAttemptDTO]
    var balances: GroupBalancesDTO
    /// Receipts posted for asynchronous allocation (pending, or finished in the last week). Absent
    /// from older servers and older caches.
    var receipts: [GroupReceiptDTO]?
    var events: [GroupEventDTO]
    let eventsComplete: Bool

    func receipt(_ id: String) -> GroupReceiptDTO? { receipts?.first { $0.id == id } }
}

/// One receipt posted into a shared group ("Add to a group"), as this member may see it. The
/// people on it get the whole receipt (`room`, in the receipt room's format with member IDs as
/// participant IDs); anyone else in the group sees only that it exists. Never part of balances
/// until it's finalized into an expense (with the same ID).
nonisolated struct GroupReceiptDTO: Codable, Hashable, Sendable, Identifiable {
    let id: String
    /// `open`, `resolving`, `readyToFinalize`, `finalized`, or `cancelled`.
    let state: String
    let hostMemberId: String
    let payerId: String?
    let participantIds: [String]
    let merchant: String
    let date: String
    let currency: String
    let total: Int?
    let revision: Int
    let createdAt: String?
    let updatedAt: String?
    let expenseId: String?
    let unreviewedCount: Int
    let viewerIsParticipant: Bool
    let room: RoomDTO?

    var isPending: Bool { state != "finalized" && state != "cancelled" }
}

/// What changed after a cursor: events in order plus the current state of every entity they touched.
nonisolated struct GroupChangesDTO: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let serverTime: String
    let revision: Int
    let after: Int
    let cursor: Int
    let cursorExpired: Bool
    let group: GroupHeaderDTO?
    let viewer: GroupViewerDTO?
    let members: [GroupMemberDTO]?
    let expenses: [GroupExpenseDTO]?
    let settlements: [GroupSettlementDTO]?
    let attempts: [GroupAttemptDTO]?
    let balances: GroupBalancesDTO?
    var receipts: [GroupReceiptDTO]?
    let events: [GroupEventDTO]?
}

nonisolated struct GroupSummaryDTO: Codable, Hashable, Sendable {
    let group: GroupHeaderDTO
    let viewer: GroupViewerDTO
    let cursor: Int
    let memberCount: Int
    let confirmedNet: Int
    let awaitingYourConfirmation: Int
    /// Pending receipts this person is on, and those waiting for them (their review, or — for
    /// the host — finishing it). Absent from older servers.
    var openReceipts: Int?
    var receiptsNeedingYou: Int?
}

nonisolated struct GroupListResponse: Codable, Sendable {
    let groups: [GroupSummaryDTO]
}

nonisolated struct GroupSnapshotResponse: Codable, Sendable {
    let snapshot: GroupSnapshotDTO
}

nonisolated struct GroupCreateResponse: Codable, Sendable {
    let snapshot: GroupSnapshotDTO
    let created: Bool
}

nonisolated struct GroupChangesResponse: Codable, Sendable {
    let changes: GroupChangesDTO
}

nonisolated struct CreateGroupRequest: Codable, Sendable {
    let groupId: String
    let name: String
    let details: String?
    let symbol: String
    let currency: String
    let simplifiesDebts: Bool
}

nonisolated struct GroupCommandEnvelope: Codable, Hashable, Sendable {
    let commandId: String
    let idempotencyKey: String
    var expectedRevision: Int
    let type: String
    let payload: JSONValue
    /// The client's cursor, so the response carries what changed since (not part of the request's identity).
    var knownCursor: Int?

    init(type: String, payload: JSONValue, expectedRevision: Int, knownCursor: Int?) {
        commandId = UUID().uuidString.lowercased()
        idempotencyKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.expectedRevision = expectedRevision
        self.type = type
        self.payload = payload
        self.knownCursor = knownCursor
    }

    /// A group command carrying a receipt change, with the receipt change's own identity: resending
    /// the same receipt change always resends the identical group request (one idempotency key, one
    /// fingerprint), so it's applied at most once.
    init(receiptChange envelope: CommandEnvelope, type: String, payload: JSONValue, knownCursor: Int?) {
        commandId = envelope.commandId
        idempotencyKey = envelope.idempotencyKey
        expectedRevision = envelope.expectedRevision
        self.type = type
        self.payload = payload
        self.knownCursor = knownCursor
    }
}

nonisolated struct GroupCommandResponse: Codable, Sendable {
    let commandId: String
    let applied: Bool
    let replayed: Bool
    let revision: Int
    let cursor: Int
    let result: JSONValue
    let changes: GroupChangesDTO?
    /// Receipt commands: the receipt as it is now (committed), for the screen that sent the change.
    var receipt: GroupReceiptDTO?
}

nonisolated struct GroupReceiptResponse: Codable, Sendable {
    let receipt: GroupReceiptDTO
}

// MARK: - Publishing a local group

nonisolated struct PublicationRequest: Codable, Hashable, Sendable {
    nonisolated struct Group: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let details: String?
        let symbol: String
        let currency: String
        let simplifiesDebts: Bool
        let createdAt: String
    }

    nonisolated struct Member: Codable, Hashable, Sendable {
        let id: String
        let displayName: String
        let handle: String?
        let removed: Bool
    }

    nonisolated struct Expense: Codable, Hashable, Sendable {
        let id: String
        let title: String
        let merchant: String?
        let date: String
        let total: Int
        let currency: String
        let category: String
        let splitMethod: String
        let payments: [ShareDTO]
        let allocations: [ShareDTO]
        let note: String?
        let createdBy: String
        let createdAt: String
        let revision: Int
        let updatedAt: String?
        let updatedBy: String?
        let deletedAt: String?
        let deletedBy: String?
    }

    nonisolated struct Settlement: Codable, Hashable, Sendable {
        let id: String
        let fromId: String
        let toId: String
        let amount: Int
        let date: String
        let recordedBy: String
        let provider: String?
    }

    nonisolated struct Event: Codable, Hashable, Sendable {
        let kind: String
        let actorMemberId: String
        let at: String
        let data: JSONValue
    }

    let publicationId: String
    let publisherMemberId: String
    let group: Group
    let members: [Member]
    let expenses: [Expense]
    let settlements: [Settlement]
    let events: [Event]
}

// MARK: - Invitations

nonisolated struct GroupInvitationRequest: Codable, Sendable {
    let seatMemberId: String?
}

nonisolated struct GroupInvitationDTO: Codable, Hashable, Sendable {
    let invitationId: String
    /// `unused`, `accepted`, `expired`, or `revoked`. Older servers don't send it; see `state(at:)`.
    var status: String?
    let seatMemberId: String?
    var createdByMemberId: String?
    /// Who joined with it (older records don't say).
    var acceptedMemberId: String?
    let createdAt: String
    let expiresAt: String
    let acceptedAt: String?
    let revokedAt: String?
    /// Returned once, when the invitation is created (only its hash is stored).
    let code: String?
    let url: String?
    let appUrl: String?
}

nonisolated struct GroupInvitationResponse: Codable, Sendable {
    let invitation: GroupInvitationDTO
}

nonisolated struct GroupInvitationListResponse: Codable, Sendable {
    let invitations: [GroupInvitationDTO]
}

/// The safe preview: no member names, balances, totals, or identifiers.
nonisolated struct GroupInvitationPreviewDTO: Codable, Hashable, Sendable {
    let groupName: String
    let symbol: String
    let currency: String
    let inviterName: String
    /// Absent from older servers.
    var ownerName: String?
    let memberCount: Int
    let expiresAt: String
    let isSeatInvitation: Bool
    let alreadyMember: Bool
}

nonisolated struct GroupInvitationPreviewResponse: Codable, Sendable {
    let invitation: GroupInvitationPreviewDTO
}

nonisolated struct AcceptGroupInvitationRequest: Codable, Sendable {
    let displayName: String
}

nonisolated struct AcceptGroupInvitationResponse: Codable, Sendable {
    let snapshot: GroupSnapshotDTO
    let joined: Bool
}

// MARK: - Direct invitations ("Find a person")

/// Exactly one of the two: a lower-cased email address, or an E.164 phone number. Sent only in the
/// request body (never a URL), so it never reaches a request log.
nonisolated struct PersonLookupRequest: Codable, Sendable {
    var email: String?
    var phone: String?
}

/// The account an email or phone number belongs to, as an invitation would show it.
nonisolated struct PersonMatchDTO: Codable, Hashable, Sendable {
    let displayName: String
    /// `s•••@example.com` or `•••• 0142`: which address or number matched, without showing it.
    let maskedIdentifier: String
    /// `available`, `invited` (an invitation is already waiting), `member`, or `you`.
    let status: String
}

nonisolated struct PersonLookupResponse: Codable, Sendable {
    /// `nil` when nobody can be invited with what was entered (always the same answer).
    let match: PersonMatchDTO?
}

/// An invitation sent to one person, as its sender (or the group's owner) sees it.
nonisolated struct SentInvitationDTO: Codable, Hashable, Sendable, Identifiable {
    let invitationId: String
    /// `pending`, `accepted`, `declined`, `cancelled`, or `expired`.
    let status: String
    let displayName: String
    let maskedIdentifier: String
    let invitedByMemberId: String
    let createdAt: String
    let expiresAt: String
    let respondedAt: String?

    var id: String { invitationId }
}

nonisolated struct SentInvitationResponse: Codable, Sendable {
    let invitation: SentInvitationDTO
}

nonisolated struct SentInvitationListResponse: Codable, Sendable {
    let invitations: [SentInvitationDTO]
}

/// An invitation waiting for this account: what a code invitation's preview shows, and no more.
nonisolated struct ReceivedInvitationDTO: Codable, Hashable, Sendable, Identifiable {
    let invitationId: String
    let status: String
    let groupName: String
    let symbol: String
    let currency: String
    let inviterName: String
    let memberCount: Int
    let createdAt: String
    let expiresAt: String

    var id: String { invitationId }
}

nonisolated struct ReceivedInvitationListResponse: Codable, Sendable {
    let invitations: [ReceivedInvitationDTO]
}

nonisolated struct AcceptDirectInvitationRequest: Codable, Sendable {}

nonisolated struct DeclinedInvitationDTO: Codable, Hashable, Sendable {
    let invitationId: String
    let status: String
    let respondedAt: String?
}

nonisolated struct DeclinedInvitationResponse: Codable, Sendable {
    let invitation: DeclinedInvitationDTO
}
