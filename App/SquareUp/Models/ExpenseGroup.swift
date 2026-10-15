import Foundation

/// A personal shared-expense group: friends, roommates, couples, families, trips.
///
/// Square Up is peer-to-peer only. Earlier builds also stored "organization" groups (budgets and
/// reimbursement); those records are excluded when a store is read and are never converted into
/// personal groups (see `LegacyRecords` and `App/ARCHITECTURE.md` "P2P scope").
nonisolated struct ExpenseGroup: Identifiable, Hashable, Sendable {
    let id: GroupID
    var name: String
    var currency: CurrencyCode
    /// SF Symbol used as the group's mark when no image exists.
    var symbolName: String
    /// Every membership ever held, including removed members (history must stay explainable).
    var memberships: [Membership]
    var createdAt: Date
    /// Optional free-text description ("Lake Tahoe, Jan 9–11").
    var details: String?
    /// Whether the settlement plan simplifies debts. Changes who pays whom, never net positions.
    var simplifiesDebts: Bool

    init(
        id: GroupID = GroupID(),
        name: String,
        currency: CurrencyCode = .usd,
        symbolName: String,
        memberships: [Membership],
        createdAt: Date,
        details: String? = nil,
        simplifiesDebts: Bool = true
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.symbolName = symbolName
        self.memberships = memberships
        self.createdAt = createdAt
        self.details = details
        self.simplifiesDebts = simplifiesDebts
    }

    /// Everyone who has ever been a member — used for balances and history.
    var memberIDs: [MemberID] { memberships.map(\.memberID) }

    /// Members who can take part in new expenses and payments.
    var activeMemberIDs: [MemberID] { memberships.filter(\.isActive).map(\.memberID) }

    func isActiveMember(_ memberID: MemberID) -> Bool {
        membership(for: memberID)?.isActive ?? false
    }

    func membership(for memberID: MemberID) -> Membership? {
        memberships.first { $0.memberID == memberID }
    }
}
