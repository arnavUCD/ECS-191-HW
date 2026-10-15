import Foundation

/// Compatibility for stores written before Square Up became peer-to-peer only (October 2026).
///
/// Earlier builds could store "organization" groups (event budgets, treasurer roles, and
/// expenses partly funded by the organization). Those concepts no longer exist in the domain.
/// Rules, applied every time a store is read:
///
/// - An organization group, and everything that belongs to it (expenses, settlements, payment
///   attempts, audit events, receipt rooms), is **excluded** from the active ledger. It is never
///   converted into a personal group, so organization-covered amounts can't become personal debt.
/// - An expense that carries legacy organization funding is excluded wherever it is found: its
///   allocations deliberately omit the organization's share, so counting it would credit that
///   share to the payer as if group members owed it.
/// - The records stay on disk untouched. Only the seeded sample organization (stable sample
///   identifiers) is deleted, by `SwiftDataLedgerStore.removeRetiredSampleData()`.
nonisolated enum LegacyRecords {
    static let personalKind = "personal"
    static let organizationKind = "organization"
    /// Milestone 7: a local group that was published as a shared group. The server is now its
    /// authority, so this local copy is kept untouched and hidden — never edited in parallel.
    static let publishedKind = "publishedShared"
    static let memberRole = "member"

    /// The seeded "Design Club" sample organization (`SampleLedger` key 103 in earlier builds).
    static let retiredSampleOrganizationID = SampleLedger.uuid(103)
}

extension GroupRecord {
    /// Written by an earlier build as an organization group; excluded from the P2P ledger.
    var isLegacyOrganization: Bool { kind == LegacyRecords.organizationKind }
    /// Published as a shared group (milestone 7); the shared copy is shown instead.
    var isPublishedCopy: Bool { kind == LegacyRecords.publishedKind }
    /// Not part of the local ledger shown on this iPhone.
    var isExcludedFromLocalLedger: Bool { isLegacyOrganization || isPublishedCopy }
}

extension ExpenseRecord {
    /// Carries organization funding from an earlier build; excluded from the P2P ledger.
    var hasLegacyOrganizationFunding: Bool { funding != nil }
}
