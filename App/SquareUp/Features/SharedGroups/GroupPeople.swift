import Foundation

/// One invitation's state, as the owner sees it. Single-use: once accepted it stays accepted.
nonisolated enum InvitationState: String, Equatable, Sendable {
    case unused
    case accepted
    case expired
    case revoked
}

extension GroupInvitationDTO {
    /// The server's status, or — for an older server that doesn't send one — derived the same way
    /// (accepted, then revoked, then expired). An unused invitation whose time ran out since it was
    /// fetched reads as expired.
    nonisolated func state(at now: Date) -> InvitationState {
        let expired = RemoteRoomMapper.timestamp(expiresAt).map { $0 <= now } ?? false
        if let status, let state = InvitationState(rawValue: status) {
            return state == .unused && expired ? .expired : state
        }
        if acceptedAt != nil { return .accepted }
        if revokedAt != nil { return .revoked }
        return expired ? .expired : .unused
    }
}

/// Everything the People screen of a shared group shows, derived without the view: the owner,
/// the people who joined with how each stands, named places still waiting (from groups shared
/// before invitations were per person), and the owner's invitations split by state.
nonisolated struct GroupPeople: Equatable, Sendable {
    nonisolated enum Standing: Equatable, Sendable {
        case settled
        case owes(Money)
        case isOwed(Money)
    }

    nonisolated struct Person: Equatable, Sendable, Identifiable {
        var id: MemberID { member.id }
        let member: Member
        let isYou: Bool
        let isOwner: Bool
        let standing: Standing
        /// Sent or received a payment that isn't confirmed yet.
        let hasPaymentInProgress: Bool
        /// Leaving or being removed needs a zero balance and no payment in progress (server-enforced).
        var canLeave: Bool { standing == .settled && !hasPaymentInProgress }
    }

    let owner: Person?
    /// Everyone else who joined: you first, then by name.
    let members: [Person]
    /// Places named when a group was shared from this iPhone, still waiting for their person.
    let waitingPlaces: [Member]
    /// People who left or were removed; their history stays.
    let former: [Member]
    /// Unused invitations, newest first (owner only).
    let awaiting: [GroupInvitationDTO]
    /// Accepted, expired, and turned-off invitations, newest first (owner only).
    let ended: [GroupInvitationDTO]
    let activeCount: Int

    static let memberLimit = 25

    var isFull: Bool { activeCount >= Self.memberLimit }

    /// - Parameters:
    ///   - status: each member's server status (`active`, `pending`, `removed`).
    ///   - invitations: the owner's invitations; empty for everyone else.
    static func make(summary: GroupDetailSummary, ownerID: MemberID?, status: (MemberID) -> String?,
                     invitations: [GroupInvitationDTO], now: Date) -> GroupPeople {
        let nets = Dictionary(summary.memberBalances.map { ($0.member.id, $0.net) }, uniquingKeysWith: { first, _ in first })
        let busy = summary.peopleWithPaymentsInProgress
        func person(_ member: Member) -> Person {
            let net = nets[member.id] ?? .zero(summary.group.currency)
            let standing: Standing = net.isPositive ? .isOwed(net) : net.isNegative ? .owes(net.magnitude) : .settled
            return Person(member: member, isYou: member.id == summary.currentUserID, isOwner: member.id == ownerID,
                          standing: standing, hasPaymentInProgress: busy.contains(member.id))
        }
        let byStatus = Dictionary(grouping: summary.members) { status($0.id) ?? "active" }
        let active = (byStatus["active"] ?? []).map(person)
        let others = active.filter { !$0.isOwner }.sorted { lhs, rhs in
            if lhs.isYou != rhs.isYou { return lhs.isYou }
            return lhs.member.displayName.localizedStandardCompare(rhs.member.displayName) == .orderedAscending
        }
        let newestFirst = invitations.sorted { $0.createdAt > $1.createdAt }
        return GroupPeople(
            owner: active.first(where: \.isOwner),
            members: others,
            waitingPlaces: byStatus["pending"] ?? [],
            former: byStatus["removed"] ?? [],
            awaiting: newestFirst.filter { $0.state(at: now) == .unused },
            ended: newestFirst.filter { $0.state(at: now) != .unused },
            activeCount: active.count
        )
    }
}
