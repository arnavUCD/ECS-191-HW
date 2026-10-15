import Foundation

/// A person who can participate in groups. Profile data only — balances are always derived.
nonisolated struct Member: Identifiable, Hashable, Sendable, Codable {
    let id: MemberID
    var displayName: String
    /// Optional short handle shown to disambiguate people with the same name.
    var handle: String?

    init(id: MemberID = MemberID(), displayName: String, handle: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
    }

    var initials: String { PersonIdentity.initials(for: displayName) }
    var firstName: String { PersonIdentity.firstName(for: displayName) }
}

nonisolated struct Membership: Hashable, Sendable, Codable {
    let memberID: MemberID
    /// Set when the member leaves or is removed. Past records keep referring to them.
    var removedAt: Date?

    init(memberID: MemberID, removedAt: Date? = nil) {
        self.memberID = memberID
        self.removedAt = removedAt
    }

    var isActive: Bool { removedAt == nil }
}
