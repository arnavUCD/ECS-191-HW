import Foundation
import SwiftData

// SwiftData persistence records.
//
// Storage representation (documented per CLAUDE.md §9):
// - Money is stored as `Int64` minor units plus an ISO 4217 code. Never floating point.
// - Small stable value types (shares, memberships, funding) are persisted as Codable values.
// - Domain types in `Models/` are the only types features see; `RecordMapping` converts.
//
// Schema version 2 (milestone 2): adds group details/simplification, membership removal,
// expense revisions and tombstones, settlement provenance, and three payload records.
// All additions are optional or defaulted, so SwiftData's lightweight migration upgrades a
// milestone 1 store automatically.
//
// Schema version 3 (milestone 3): adds `ReceiptRoomRecord` and nothing else — every version 2
// model is unchanged, so `SquareUpSchemaV2` can reference the live classes and the explicit
// V2 → V3 stage (`SquareUpMigrationPlan`) is a lightweight, additive migration. Any future change
// to an existing model must first freeze the current classes into a nested `VersionedSchema`.
//
// P2P scope (October 2026): Square Up became peer-to-peer only. `GroupRecord.kind` and `budget`,
// `ExpenseRecord.funding`, and `MembershipValue.roles` remain as legacy storage fields so stores
// written by earlier builds still open without a schema change; nothing reads them except
// `LegacyRecords`, which excludes organization data from the active ledger.
//
// Payment destinations, payment attempts, and audit events are stored as a JSON payload of the
// domain value plus indexed identifiers. These types are stable, append-mostly values whose
// fields are only ever read together; storing them whole keeps both stores trivially identical.

nonisolated struct ShareValue: Codable, Hashable, Sendable {
    var memberID: UUID
    var minorUnits: Int64
}

nonisolated struct MembershipValue: Codable, Hashable, Sendable {
    var memberID: UUID
    var roles: [String]
    var removedAt: Date?
}

/// Legacy storage only (organization funding written by earlier builds). Never mapped to the domain.
nonisolated struct FundingValue: Codable, Hashable, Sendable {
    var requestedMinorUnits: Int64
    var approvedMinorUnits: Int64?
    var status: String
    var reimburseeID: UUID
    var submittedAt: Date
    var reviewerID: UUID?
    var decidedAt: Date?
    var decisionNote: String?
}

/// Legacy storage only (organization event budgets written by earlier builds). Never mapped to the domain.
nonisolated struct BudgetValue: Codable, Hashable, Sendable {
    var name: String
    var allocationMinorUnits: Int64
}

@Model
final class MemberRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var handle: String?
    /// Prototype identity: exactly one record is the device's current user until real
    /// authentication exists (overview: "seeded demonstration users").
    var isCurrentUser: Bool

    init(id: UUID, displayName: String, handle: String?, isCurrentUser: Bool) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.isCurrentUser = isCurrentUser
    }
}

@Model
final class GroupRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var kind: String
    var currencyCode: String
    var symbolName: String
    var memberships: [MembershipValue]
    var budget: BudgetValue?
    var createdAt: Date
    var details: String?
    var simplifiesDebts = true

    @Relationship(deleteRule: .cascade, inverse: \ExpenseRecord.group)
    var expenses: [ExpenseRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SettlementRecord.group)
    var settlements: [SettlementRecord] = []

    init(
        id: UUID,
        name: String,
        kind: String,
        currencyCode: String,
        symbolName: String,
        memberships: [MembershipValue],
        budget: BudgetValue?,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currencyCode = currencyCode
        self.symbolName = symbolName
        self.memberships = memberships
        self.budget = budget
        self.createdAt = createdAt
    }
}

@Model
final class ExpenseRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var merchant: String?
    var date: Date
    var totalMinorUnits: Int64
    var currencyCode: String
    var category: String
    var splitMethod: String
    var payments: [ShareValue]
    var allocations: [ShareValue]
    var funding: FundingValue?
    var note: String?
    var createdByID: UUID
    var createdAt: Date
    var revision = 1
    var updatedAt: Date?
    var updatedByID: UUID?
    var deletedAt: Date?
    var deletedByID: UUID?
    var group: GroupRecord?

    init(
        id: UUID,
        title: String,
        merchant: String?,
        date: Date,
        totalMinorUnits: Int64,
        currencyCode: String,
        category: String,
        splitMethod: String,
        payments: [ShareValue],
        allocations: [ShareValue],
        funding: FundingValue?,
        note: String?,
        createdByID: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.merchant = merchant
        self.date = date
        self.totalMinorUnits = totalMinorUnits
        self.currencyCode = currencyCode
        self.category = category
        self.splitMethod = splitMethod
        self.payments = payments
        self.allocations = allocations
        self.funding = funding
        self.note = note
        self.createdByID = createdByID
        self.createdAt = createdAt
    }
}

@Model
final class SettlementRecord {
    @Attribute(.unique) var id: UUID
    var fromID: UUID
    var toID: UUID
    var amountMinorUnits: Int64
    var currencyCode: String
    var date: Date
    var note: String?
    var recordedByID: UUID
    var provider: String?
    var attemptID: UUID?
    var confirmedAt: Date?
    var confirmedByID: UUID?
    var group: GroupRecord?

    init(
        id: UUID,
        fromID: UUID,
        toID: UUID,
        amountMinorUnits: Int64,
        currencyCode: String,
        date: Date,
        note: String?,
        recordedByID: UUID
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.date = date
        self.note = note
        self.recordedByID = recordedByID
    }
}

@Model
final class PaymentDestinationRecord {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    /// JSON-encoded `PaymentDestination`. Sensitive; never logged.
    var payload: Data

    init(id: UUID, ownerID: UUID, payload: Data) {
        self.id = id
        self.ownerID = ownerID
        self.payload = payload
    }
}

@Model
final class PaymentAttemptRecord {
    @Attribute(.unique) var id: UUID
    var groupID: UUID
    var state: String
    /// JSON-encoded `PaymentAttempt`.
    var payload: Data

    init(id: UUID, groupID: UUID, state: String, payload: Data) {
        self.id = id
        self.groupID = groupID
        self.state = state
        self.payload = payload
    }
}

@Model
final class AuditEventRecord {
    @Attribute(.unique) var id: UUID
    var groupID: UUID
    var sequence: Int
    /// JSON-encoded `AuditEvent`. Append-only.
    var payload: Data

    init(id: UUID, groupID: UUID, sequence: Int, payload: Data) {
        self.id = id
        self.groupID = groupID
        self.sequence = sequence
        self.payload = payload
    }
}

/// Milestone 3: one receipt draft or Live Receipt Room. Image bytes are files on disk
/// (`ReceiptAssetStore`); this record holds references and metadata only.
@Model
final class ReceiptRoomRecord {
    @Attribute(.unique) var id: UUID
    var groupID: UUID?
    var state: String
    /// The itemized expense created at finalization.
    var expenseID: UUID?
    var updatedAt: Date
    /// JSON-encoded `ReceiptRoom`, including recognized receipt text. Sensitive; never logged.
    var payload: Data

    init(id: UUID, groupID: UUID?, state: String, expenseID: UUID?, updatedAt: Date, payload: Data) {
        self.id = id
        self.groupID = groupID
        self.state = state
        self.expenseID = expenseID
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

/// The milestone 2 schema, exactly as shipped (no versioned schema was declared then).
nonisolated enum SquareUpSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            MemberRecord.self,
            GroupRecord.self,
            ExpenseRecord.self,
            SettlementRecord.self,
            PaymentDestinationRecord.self,
            PaymentAttemptRecord.self,
            AuditEventRecord.self,
        ]
    }
}

/// Milestone 3: adds receipt rooms.
nonisolated enum SquareUpSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { SquareUpSchemaV2.models + [ReceiptRoomRecord.self] }
}

/// Deliberate migration path (milestone 3 §12.3). V2 → V3 only adds an entity.
nonisolated enum SquareUpMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SquareUpSchemaV2.self, SquareUpSchemaV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SquareUpSchemaV2.self, toVersion: SquareUpSchemaV3.self)]
    }
}

nonisolated enum SquareUpSchema {
    static var models: [any PersistentModel.Type] { SquareUpSchemaV3.models }
}
