import Foundation

/// The room lifecycle (milestone 3 §8.2). Transitions are enforced by `ReceiptRoomEngine`.
nonisolated enum ReceiptRoomState: String, Codable, Sendable, CaseIterable {
    /// The receipt is still being captured or reviewed.
    case draft
    /// The receipt is confirmed; the host is choosing participants.
    case ready
    /// Participants may claim, share, and dispute.
    case open
    /// Claiming is locked; the host resolves what remains.
    case resolving
    /// Everything is allocated and no dispute remains; awaiting the host's final review.
    case readyToFinalize
    /// An expense exists and the room is locked.
    case finalized
    /// Abandoned. Kept for history once the room had been opened.
    case cancelled

    var isTerminal: Bool { self == .finalized || self == .cancelled }
    /// States in which item allocations can change.
    var allowsAllocationChanges: Bool { self == .open || self == .resolving }
}

/// One participant's claim on an item (milestone 3 §10.8).
nonisolated enum ClaimMode: Hashable, Codable, Sendable {
    /// The whole item. Exclusive.
    case full
    /// An equal part, alongside the other claimants.
    case equalShare
    /// A weighted part ("2 shares").
    case shares(Int)
    /// An exact amount; all claimants' exact amounts must add up to the item.
    case exact(Money)
    /// A whole number of the line's printed quantity ("2 of the 3 beers"). Units nobody claimed
    /// stay unassigned; they're never spread over the people who did claim.
    case units(Int)

    var isUnits: Bool { if case .units = self { true } else { false } }
}

/// How many of a line's printed quantity one person had.
nonisolated struct MemberUnits: Hashable, Codable, Sendable {
    let memberID: MemberID
    let units: Int

    init(_ memberID: MemberID, _ units: Int) {
        self.memberID = memberID
        self.units = units
    }
}

nonisolated struct ReceiptClaim: Hashable, Codable, Sendable {
    let itemID: ReceiptItemID
    let memberID: MemberID
    var mode: ClaimMode
    let createdAt: Date
    var updatedAt: Date
    /// The room revision at which this claim was last written.
    var revision: Int
}

nonisolated enum DisputeTarget: Hashable, Codable, Sendable {
    case item(ReceiptItemID)
    case charge(ReceiptChargeID)
}

nonisolated enum DisputeStatus: String, Codable, Sendable {
    case open
    /// The host changed something to address it.
    case resolved
    /// The host decided no change is needed (a note is required).
    case dismissed
}

/// "That's not mine" (milestone 3 §8.10). An open dispute blocks finalization.
nonisolated struct ReceiptDispute: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptDisputeID
    let target: DisputeTarget
    let raisedBy: MemberID
    let note: String?
    let createdAt: Date
    var status: DisputeStatus
    var resolvedBy: MemberID?
    var resolvedAt: Date?
    var resolutionNote: String?

    var isOpen: Bool { status == .open }
}

/// How a shared item is divided when set explicitly in the shared-item editor.
nonisolated enum ItemSplit: Hashable, Codable, Sendable {
    case equal([MemberID])
    case shares([MemberWeight])
    case exact([Share])
    /// By the line's printed quantity; may leave units for others to claim, never more than printed.
    case units([MemberUnits])

    var memberIDs: [MemberID] {
        switch self {
        case .equal(let ids): ids
        case .shares(let weights): weights.map(\.memberID)
        case .exact(let shares): shares.map(\.memberID)
        case .units(let counts): counts.filter { $0.units > 0 }.map(\.memberID)
        }
    }
}

/// What changed in a host's receipt revision after claims began (milestone 3 §8.11).
nonisolated struct ReceiptRevisionChange: Hashable, Codable, Sendable {
    var financialItemIDs: [ReceiptItemID] = []
    var removedItemIDs: [ReceiptItemID] = []
    var addedItemIDs: [ReceiptItemID] = []
    var changedChargeIDs: [ReceiptChargeID] = []
    var totalChanged = false
    var nonFinancialOnly: Bool {
        financialItemIDs.isEmpty && removedItemIDs.isEmpty && addedItemIDs.isEmpty && changedChargeIDs.isEmpty && !totalChanged
    }
}

/// The room's own audit trail. Every entry records the actual (possibly simulated) actor.
nonisolated struct ReceiptRoomEvent: Hashable, Codable, Sendable {
    nonisolated enum Kind: Hashable, Codable, Sendable {
        case created(source: ReceiptImportSource?)
        case recognitionFinished(RecognitionProviderKind, itemCount: Int)
        /// A review save. `proposal` is the machine proposal when this is the first save after recognition.
        case receiptEdited(revision: Int)
        case receiptConfirmed(groupID: GroupID, payerID: MemberID, total: Money)
        case opened(participants: [MemberID])
        case participantsChanged(added: [MemberID], removed: [MemberID], clearedClaims: [ReceiptClaim])
        case claimed(ReceiptItemID, ClaimMode)
        case unclaimed(ReceiptItemID, previous: ClaimMode)
        case itemSplitSet(ReceiptItemID, previous: [ReceiptClaim], split: ItemSplit)
        case itemAssigned(ReceiptItemID, previous: [ReceiptClaim], split: ItemSplit)
        case disputed(ReceiptDisputeID, DisputeTarget)
        case disputeResolved(ReceiptDisputeID, DisputeStatus)
        case chargeAllocationChanged(ReceiptChargeID, from: ChargeAllocation, to: ChargeAllocation)
        /// A host edit after claims began; previous claims on affected items are preserved here.
        case receiptRevised(ReceiptRevisionChange, clearedClaims: [ReceiptClaim], previousItems: [ReceiptLineItem])
        case portionReviewed
        case payerAcceptanceChanged(Bool)
        case stateChanged(from: ReceiptRoomState, to: ReceiptRoomState)
        case finalized(ExpenseID)
        case cancelled
        case imagesRemoved
        /// Milestone 4: the host's device recorded the shared room's authoritative state.
        case sharedRoomAdopted(serverRevision: Int)
    }

    let sequence: Int
    let actorID: MemberID
    let date: Date
    /// The room revision after this event.
    let revision: Int
    let kind: Kind
}

/// Who absorbed a cent of rounding, and on what (disclosed in the room and final review).
nonisolated struct RoundingNote: Hashable, Codable, Sendable {
    nonisolated enum Source: Hashable, Codable, Sendable {
        case item(ReceiptItemID)
        case charge(ReceiptChargeID)
    }

    let source: Source
    let memberID: MemberID
    /// Positive: paid this much more than an exact division; negative: less.
    let amount: Money
}

/// One person's breakdown (milestone 3 §8.9 running totals).
nonisolated struct ParticipantTotal: Hashable, Codable, Sendable {
    let memberID: MemberID
    var items: Money
    var tax: Money
    var tip: Money
    /// Service charges and other fees.
    var fees: Money
    /// Negative or zero.
    var discounts: Money
    var adjustments: Money
    var itemShares: [ItemShare]

    nonisolated struct ItemShare: Hashable, Codable, Sendable {
        let itemID: ReceiptItemID
        let amount: Money
    }

    static func zero(_ memberID: MemberID, _ currency: CurrencyCode) -> ParticipantTotal {
        let zero = Money.zero(currency)
        return ParticipantTotal(memberID: memberID, items: zero, tax: zero, tip: zero, fees: zero, discounts: zero,
                                adjustments: zero, itemShares: [])
    }

    var total: Money { items + tax + tip + fees + discounts + adjustments }
    var charges: Money { tax + tip + fees + discounts + adjustments }
}

/// The immutable record frozen at finalization (milestone 3 §10.9). It explains the expense even
/// if the room implementation changes later.
nonisolated struct ReceiptAllocationSnapshot: Hashable, Codable, Sendable {
    nonisolated struct Item: Hashable, Codable, Sendable {
        let id: ReceiptItemID
        let name: String
        let quantity: Int?
        let lineTotal: Money
        let isRefund: Bool
        let shares: [Share]
    }

    nonisolated struct Charge: Hashable, Codable, Sendable {
        let id: ReceiptChargeID
        let kind: ReceiptChargeKind
        let label: String
        let amount: Money
        let allocation: ChargeAllocation
        let shares: [Share]
    }

    let merchant: String
    let date: Date
    let total: Money
    let items: [Item]
    let charges: [Charge]
    let participants: [ParticipantTotal]
    let payments: [Share]
    let rounding: [RoundingNote]
    let roomRevision: Int
    let finalizedAt: Date
    let finalizedBy: MemberID
}

/// A Live Receipt Room (milestone 3 §10.7) — the aggregate for one receipt from capture to
/// finalization. The receipt draft lives inside it, so drafts and open rooms persist the same way.
nonisolated struct ReceiptRoom: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptRoomID
    /// Chosen during review when the flow started globally.
    var groupID: GroupID?
    /// The person who captured the receipt; resolves, allocates charges, and finalizes.
    let hostID: MemberID
    /// Who paid the bill. The expense records the full receipt total as their payment.
    var payerID: MemberID?
    var state: ReceiptRoomState
    var receipt: ReceiptDraft
    var participantIDs: [MemberID]
    var claims: [ReceiptClaim]
    var disputes: [ReceiptDispute]
    /// The room revision at which each participant last marked their portion reviewed.
    var reviews: [ReviewMark]
    /// Participants whose claims were affected by a host edit and should look again.
    var needsReview: [MemberID]
    /// The host confirmed the payer intentionally keeps the entire receipt (§9.1).
    var payerAcceptsFullReceipt: Bool
    /// Increments after every accepted command; commands carry the revision they were based on.
    var revision: Int
    var history: [ReceiptRoomEvent]
    let createdAt: Date
    var confirmedAt: Date?
    var openedAt: Date?
    var finalizedAt: Date?
    var cancelledAt: Date?
    var finalExpenseID: ExpenseID?
    var finalSnapshot: ReceiptAllocationSnapshot?

    init(id: ReceiptRoomID, groupID: GroupID?, hostID: MemberID, receipt: ReceiptDraft, createdAt: Date) {
        self.id = id
        self.groupID = groupID
        self.hostID = hostID
        payerID = nil
        state = .draft
        self.receipt = receipt
        participantIDs = []
        claims = []
        disputes = []
        reviews = []
        needsReview = []
        payerAcceptsFullReceipt = false
        revision = 1
        history = []
        self.createdAt = createdAt
    }

    var title: String { receipt.title }
    var openDisputes: [ReceiptDispute] { disputes.filter(\.isOpen) }
    func claims(for itemID: ReceiptItemID) -> [ReceiptClaim] { claims.filter { $0.itemID == itemID } }
    func claim(on itemID: ReceiptItemID, by memberID: MemberID) -> ReceiptClaim? {
        claims.first { $0.itemID == itemID && $0.memberID == memberID }
    }

    func reviewedRevision(of memberID: MemberID) -> Int? { reviews.first { $0.memberID == memberID }?.revision }
    func disputes(on target: DisputeTarget) -> [ReceiptDispute] { disputes.filter { $0.target == target } }
}

/// A participant's "I've reviewed my portion" mark at a room revision.
nonisolated struct ReviewMark: Hashable, Codable, Sendable {
    let memberID: MemberID
    let revision: Int
}
