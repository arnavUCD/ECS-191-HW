import Foundation

/// The room filters (milestone 3 §13.3).
nonisolated enum RoomFilter: String, CaseIterable, Identifiable, Sendable {
    case all, mine, unclaimed, shared, disputed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .mine: String(localized: "Mine")
        case .unclaimed: String(localized: "Unclaimed")
        case .shared: String(localized: "Shared")
        case .disputed: String(localized: "Disputed")
        }
    }
}

/// An item's claim state (§8.5), in priority order for display.
nonisolated enum ItemClaimState: Hashable, Sendable {
    case note
    case unclaimed
    case claimed(MemberID)
    case shared([MemberID])
    /// Exact claims leave money unassigned, or the split is invalid.
    case needsAttention
    case disputed
}

/// Everything the room screen shows, derived from one snapshot for one acting participant.
/// Pure and unit-tested; the view never computes money.
nonisolated struct ReceiptRoomSummary: Equatable, Sendable {
    nonisolated struct ItemLine: Identifiable, Equatable, Sendable {
        let item: ReceiptLineItem
        let allocation: ItemAllocation
        let state: ItemClaimState
        let isResolved: Bool
        /// The acting person's part of this item, if any.
        let yourShare: Money?
        let openDisputes: [ReceiptDispute]
        var id: ReceiptItemID { item.id }
    }

    let room: ReceiptRoom
    let allocation: ReceiptAllocation
    let readiness: [ReadinessIssue]
    let members: [MemberID: Member]
    let names: [MemberID: String]
    let actorID: MemberID
    let currentUserID: MemberID
    let group: ExpenseGroup?
    let lines: [ItemLine]

    static func make(room: ReceiptRoom, snapshot: LedgerSnapshot, actorID: MemberID) -> ReceiptRoomSummary {
        let allocation = ReceiptAllocationEngine.allocate(room)
        let group = room.groupID.flatMap(snapshot.group)
        let people = (room.participantIDs + [room.hostID] + [room.payerID].compactMap { $0 }).compactMap { snapshot.members[$0] }
        let lines = room.receipt.items.map { item -> ItemLine in
            let itemAllocation = allocation.item(item.id)
                ?? ItemAllocation(itemID: item.id, status: .unclaimed, shares: [], rounding: [], claimants: [])
            let disputes = room.disputes(on: .item(item.id))
            let open = disputes.filter(\.isOpen)
            let state: ItemClaimState
            if item.isNote {
                state = .note
            } else if !open.isEmpty {
                state = .disputed
            } else {
                switch itemAllocation.status {
                case .note: state = .note
                case .unclaimed: state = .unclaimed
                case .partial, .invalid: state = .needsAttention
                case .allocated: state = itemAllocation.isShared ? .shared(itemAllocation.claimants) : .claimed(itemAllocation.claimants[0])
                }
            }
            return ItemLine(
                item: item, allocation: itemAllocation, state: state, isResolved: open.isEmpty && !disputes.isEmpty,
                yourShare: itemAllocation.shares.first { $0.memberID == actorID }?.amount, openDisputes: open
            )
        }
        return ReceiptRoomSummary(
            room: room, allocation: allocation, readiness: ReceiptRoomReadiness.issues(for: room, allocation: allocation, group: group),
            members: snapshot.members, names: PersonIdentity.shortLabels(for: Array(Set(people))), actorID: actorID,
            currentUserID: snapshot.currentUserID, group: group, lines: lines
        )
    }

    var isActorHost: Bool { actorID == room.hostID }
    var isActorParticipant: Bool { room.participantIDs.contains(actorID) }
    var you: ParticipantTotal { allocation.participant(actorID) }
    var currency: CurrencyCode { room.receipt.currencyCode }
    var total: Money { room.receipt.total.value ?? .zero(currency) }
    var allocated: Money { allocation.allocatedTotal }
    var remaining: Money { allocation.remaining ?? .zero(currency) }
    var unclaimedCount: Int { lines.filter { $0.state == .unclaimed }.count }
    var disputedCount: Int { room.openDisputes.count }
    var canClaim: Bool { room.state == .open || (room.state == .resolving && isActorHost) }
    var needsYourReview: Bool { room.needsReview.contains(actorID) }

    /// "Previewing as Maya" participants: the host first, then everyone in the room.
    var identities: [Member] {
        var ids = [room.hostID]
        for id in room.participantIDs where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { members[$0] }
    }

    func name(_ id: MemberID) -> String { names[id] ?? members[id]?.displayName ?? String(localized: "Someone") }

    func lines(for filter: RoomFilter) -> [ItemLine] {
        switch filter {
        case .all: lines
        case .mine: lines.filter { $0.yourShare != nil || $0.allocation.claimants.contains(actorID) }
        case .unclaimed: lines.filter { $0.state == .unclaimed || $0.state == .needsAttention }
        case .shared: lines.filter { if case .shared = $0.state { true } else { false } }
        case .disputed: lines.filter { $0.state == .disputed || $0.isResolved }
        }
    }

    func count(_ filter: RoomFilter) -> Int { lines(for: filter).count }

    /// "Shared by Maya, Alex, and Priya" — for the item row and VoiceOver.
    func stateText(_ line: ItemLine) -> String {
        switch line.state {
        case .note: return String(localized: "Note · not split")
        case .unclaimed: return String(localized: "Unclaimed")
        case .claimed(let id): return id == actorID ? String(localized: "Yours") : String(localized: "Claimed by \(name(id))")
        case .shared(let ids):
            let list = ids.map { $0 == actorID ? String(localized: "you") : name($0) }.formatted(.list(type: .and))
            return String(localized: "Shared by \(list)")
        case .needsAttention:
            if case .partial(let remaining) = line.allocation.status {
                return String(localized: "\(MoneyFormatting.string(remaining.magnitude)) not assigned")
            }
            return String(localized: "Split needs fixing")
        case .disputed:
            let raisers = line.openDisputes.map { name($0.raisedBy) }.formatted(.list(type: .and))
            return String(localized: "Disputed by \(raisers)")
        }
    }

    func chargeStrategyText(_ charge: ReceiptCharge) -> String {
        switch charge.allocation {
        case .equal(let ids?):
            String(localized: "Equally among \(ids.map(name).formatted(.list(type: .and)))")
        case .payer:
            String(localized: "\(room.payerID.map(name) ?? String(localized: "Payer")) covers it")
        default:
            ReceiptLanguage.name(charge.allocation.kind)
        }
    }
}
