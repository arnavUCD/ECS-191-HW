import Foundation
import Observation
import OSLog
import SwiftData

/// The local, offline-first ledger backed by SwiftData.
///
/// Every mutation runs through `LedgerEngine` and the resulting changes are applied and saved in
/// one transaction (all or nothing). Runs on the main actor using the container's main context —
/// appropriate for prototype data volume; reads can move to a `@ModelActor` later without
/// changing this type's interface.
@Observable
final class SwiftDataLedgerStore: LedgerStore {
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeID: () -> UUID
    private(set) var revision = 0

    init(container: ModelContainer, now: @escaping () -> Date = { .now }, makeID: @escaping () -> UUID = UUID.init) {
        self.container = container
        self.now = now
        self.makeID = makeID
    }

    // MARK: Reading

    func snapshot() async throws -> LedgerSnapshot {
        try readSnapshot()
    }

    private func readSnapshot() throws -> LedgerSnapshot {
        do {
            let members = try context.fetch(FetchDescriptor<MemberRecord>(sortBy: [SortDescriptor(\.displayName)]))
            guard let me = members.first(where: \.isCurrentUser) else { throw LedgerError.currentUserMissing }
            // P2P scope: legacy organization groups and everything belonging to them are excluded
            // before decoding (see `LegacyRecords`).
            let allGroups = try context.fetch(FetchDescriptor<GroupRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            // Milestone 7: a group published as a shared group is shown from the server instead.
            let groups = allGroups.filter { !$0.isExcludedFromLocalLedger }
            let excludedGroupIDs = Set(allGroups.filter(\.isExcludedFromLocalLedger).map(\.id))
            var expenses: [Expense] = []
            var settlements: [Settlement] = []
            for group in groups {
                let groupID = GroupID(group.id)
                expenses += group.expenses.filter { !$0.hasLegacyOrganizationFunding }.map { $0.domain(groupID: groupID) }
                settlements += group.settlements.map { $0.domain(groupID: groupID) }
            }
            let destinations = try context.fetch(FetchDescriptor<PaymentDestinationRecord>())
                .map { try PayloadCoding.decode(PaymentDestination.self, from: $0.payload) }
            let attempts = try context.fetch(FetchDescriptor<PaymentAttemptRecord>())
                .filter { !excludedGroupIDs.contains($0.groupID) }
                .map { try PayloadCoding.decode(PaymentAttempt.self, from: $0.payload) }
            let events = try context.fetch(FetchDescriptor<AuditEventRecord>(sortBy: [SortDescriptor(\.sequence)]))
                .filter { !excludedGroupIDs.contains($0.groupID) }
                .map { try PayloadCoding.decode(AuditEvent.self, from: $0.payload) }
            let rooms = try context.fetch(FetchDescriptor<ReceiptRoomRecord>())
                .filter { $0.groupID.map { !excludedGroupIDs.contains($0) } ?? true }
                .map { try PayloadCoding.decode(ReceiptRoom.self, from: $0.payload) }
            return LedgerSnapshot(
                currentUserID: MemberID(me.id),
                members: members.map(\.domain),
                groups: groups.map(\.domain),
                expenses: expenses,
                settlements: settlements,
                paymentDestinations: destinations,
                paymentAttempts: attempts,
                events: events,
                receiptRooms: rooms
            )
        } catch let error as LedgerError {
            throw error
        } catch {
            Log.persistence.error("Snapshot fetch failed: \(String(describing: type(of: error)), privacy: .public)")
            throw LedgerError.storage(String(describing: type(of: error)))
        }
    }

    // MARK: Writing

    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult {
        let state = try readSnapshot()
        let result = try LedgerEngine.perform(command, on: state, actor: actor ?? state.currentUserID, now: now(), makeID: makeID)
        guard !result.isNoOp else { return result }
        do {
            try apply(result.changes)
        } catch {
            context.rollback()
            Log.persistence.error("Apply failed: \(String(describing: type(of: error)), privacy: .public)")
            throw LedgerError.storage(String(describing: type(of: error)))
        }
        try save()
        Log.persistence.info("Applied \(result.changes.count, privacy: .public) ledger changes")
        return result
    }

    func resetToSampleData(referenceDate: Date) async throws {
        try eraseRecords()
        try insert(SampleLedger.make(referenceDate: referenceDate))
        try save()
    }

    func eraseAll() async throws {
        try eraseRecords()
        try save()
    }

    /// Seeds sample data only if the store has never been populated.
    func seedIfEmpty(referenceDate: Date) throws {
        let count = try context.fetchCount(FetchDescriptor<MemberRecord>())
        guard count == 0 else { return }
        try insert(SampleLedger.make(referenceDate: referenceDate))
        try save()
        Log.persistence.info("Seeded sample ledger")
    }

    /// P2P scope: deletes the seeded "Design Club" sample organization written by earlier builds,
    /// and only that. The record must carry both the stable sample identifier and the stored
    /// organization kind, so a user's own data can never match. Its expenses and settlements go
    /// with it (cascade), along with payment attempts, audit events, and receipt rooms filed under
    /// it. Other legacy organization groups are left on disk and excluded on read (`LegacyRecords`).
    /// Seeded people and their payment methods are kept: they may appear in personal groups.
    func removeRetiredSampleData() throws {
        let id = LegacyRecords.retiredSampleOrganizationID
        guard let group = try fetchGroup(id), group.isLegacyOrganization else { return }
        context.delete(group)
        for record in try context.fetch(FetchDescriptor<PaymentAttemptRecord>(predicate: #Predicate { $0.groupID == id })) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<AuditEventRecord>(predicate: #Predicate { $0.groupID == id })) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<ReceiptRoomRecord>(predicate: #Predicate { $0.groupID == id })) {
            context.delete(record)
        }
        try save()
        Log.persistence.info("Removed the retired sample organization")
    }

    /// Milestone 7: hides a local group after it was published as a shared group, so there is
    /// never a second editable copy. The record and its history stay on disk, untouched.
    func markPublished(_ groupID: GroupID) async throws {
        guard let group = try fetchGroup(groupID.rawValue), !group.isPublishedCopy else { return }
        group.kind = LegacyRecords.publishedKind
        try save()
        revision += 1
        Log.persistence.info("Hid a local group that is now shared")
    }

    /// Inserts an arbitrary snapshot. Used by seeding, previews, and tests.
    func insert(_ snapshot: LedgerSnapshot) throws {
        for member in snapshot.members.values {
            context.insert(MemberRecord(member, isCurrentUser: member.id == snapshot.currentUserID))
        }
        var changes: [LedgerChange] = snapshot.groups.map { .upsertGroup($0) }
        changes += snapshot.allExpenses.map { .upsertExpense($0) }
        changes += snapshot.settlements.map { .upsertSettlement($0) }
        changes += snapshot.paymentDestinations.map { .upsertDestination($0) }
        changes += snapshot.paymentAttempts.map { .upsertAttempt($0) }
        changes += snapshot.events.map { .appendEvent($0) }
        changes += snapshot.receiptRooms.map { .upsertRoom($0) }
        try apply(changes)
    }

    // MARK: Applying changes

    private func apply(_ changes: [LedgerChange]) throws {
        for change in changes {
            switch change {
            case .upsertMember(let member):
                if let record = try fetchMember(member.id.rawValue) {
                    record.update(from: member)
                } else {
                    context.insert(MemberRecord(member, isCurrentUser: false))
                }
            case .upsertGroup(let group):
                if let record = try fetchGroup(group.id.rawValue) {
                    record.update(from: group)
                } else {
                    context.insert(GroupRecord(group))
                }
            case .upsertExpense(let expense):
                if let record = try fetchExpense(expense.id.rawValue) {
                    record.update(from: expense)
                } else {
                    let record = ExpenseRecord(expense)
                    context.insert(record)
                    record.group = try fetchGroup(expense.groupID.rawValue)
                }
            case .upsertSettlement(let settlement):
                if let record = try fetchSettlement(settlement.id.rawValue) {
                    record.update(from: settlement)
                } else {
                    let record = SettlementRecord(settlement)
                    context.insert(record)
                    record.group = try fetchGroup(settlement.groupID.rawValue)
                }
            case .upsertDestination(let destination):
                let payload = try PayloadCoding.encode(destination)
                if let record = try fetchDestination(destination.id.rawValue) {
                    record.payload = payload
                } else {
                    context.insert(PaymentDestinationRecord(id: destination.id.rawValue, ownerID: destination.ownerID.rawValue, payload: payload))
                }
            case .deleteDestination(let id):
                if let record = try fetchDestination(id.rawValue) { context.delete(record) }
            case .upsertAttempt(let attempt):
                let payload = try PayloadCoding.encode(attempt)
                if let record = try fetchAttempt(attempt.id.rawValue) {
                    record.payload = payload
                    record.state = attempt.state.rawValue
                } else {
                    context.insert(PaymentAttemptRecord(id: attempt.id.rawValue, groupID: attempt.groupID.rawValue,
                                                        state: attempt.state.rawValue, payload: payload))
                }
            case .appendEvent(let event):
                if try fetchEvent(event.id.rawValue) == nil {
                    context.insert(AuditEventRecord(id: event.id.rawValue, groupID: event.groupID.rawValue,
                                                    sequence: event.sequence, payload: try PayloadCoding.encode(event)))
                }
            case .setCurrentUser(let memberID):
                for record in try context.fetch(FetchDescriptor<MemberRecord>()) {
                    record.isCurrentUser = record.id == memberID.rawValue
                }
            case .upsertRoom(let room):
                let payload = try PayloadCoding.encode(room)
                if let record = try fetchRoom(room.id.rawValue) {
                    record.groupID = room.groupID?.rawValue
                    record.state = room.state.rawValue
                    record.expenseID = room.finalExpenseID?.rawValue
                    record.updatedAt = room.receipt.updatedAt
                    record.payload = payload
                } else {
                    context.insert(ReceiptRoomRecord(id: room.id.rawValue, groupID: room.groupID?.rawValue, state: room.state.rawValue,
                                                     expenseID: room.finalExpenseID?.rawValue, updatedAt: room.receipt.updatedAt, payload: payload))
                }
            case .deleteRoom(let id):
                if let record = try fetchRoom(id.rawValue) { context.delete(record) }
            }
        }
    }

    private func first<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchMember(_ id: UUID) throws -> MemberRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchGroup(_ id: UUID) throws -> GroupRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchExpense(_ id: UUID) throws -> ExpenseRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchSettlement(_ id: UUID) throws -> SettlementRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchDestination(_ id: UUID) throws -> PaymentDestinationRecord? {
        try first(FetchDescriptor(predicate: #Predicate { $0.id == id }))
    }

    private func fetchAttempt(_ id: UUID) throws -> PaymentAttemptRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchEvent(_ id: UUID) throws -> AuditEventRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }
    private func fetchRoom(_ id: UUID) throws -> ReceiptRoomRecord? { try first(FetchDescriptor(predicate: #Predicate { $0.id == id })) }

    /// Deletes record by record. Batch deletes (`context.delete(model:)`) bypass relationship
    /// rules and Core Data rejects them for these inverse relationships.
    private func eraseRecords() throws {
        for group in try context.fetch(FetchDescriptor<GroupRecord>()) {
            context.delete(group) // cascades to its expenses and settlements
        }
        for member in try context.fetch(FetchDescriptor<MemberRecord>()) { context.delete(member) }
        for record in try context.fetch(FetchDescriptor<PaymentDestinationRecord>()) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<PaymentAttemptRecord>()) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<AuditEventRecord>()) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<ReceiptRoomRecord>()) { context.delete(record) }
    }

    private func save() throws {
        do {
            try context.save()
            revision += 1
        } catch {
            context.rollback()
            Log.persistence.error("Save failed: \(String(describing: type(of: error)), privacy: .public)")
            throw LedgerError.storage(String(describing: type(of: error)))
        }
    }
}

nonisolated enum ModelContainerFactory {
    static let storeName = "SquareUp"

    /// The current schema, opened through the explicit migration plan so a milestone 2 store
    /// upgrades deliberately (milestone 3 §12.3).
    @MainActor
    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SquareUpSchemaV3.self)
        let configuration = ModelConfiguration(storeName, schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: SquareUpMigrationPlan.self, configurations: [configuration])
    }

    /// DEBUG/UI tests only: deletes the default on-disk store files.
    static func eraseOnDiskStore() {
        let url = ModelConfiguration(storeName).url
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// An on-disk store at an explicit location (relaunch/persistence and migration tests).
    @MainActor
    static func make(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SquareUpSchemaV3.self)
        return try ModelContainer(for: schema, migrationPlan: SquareUpMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: url)])
    }
}

extension SwiftDataLedgerStore: LocalIdentityPreparing {
    /// A new account's empty ledger gets one member, the signed-in person, as its current user.
    /// A ledger that already has a current user keeps it (and its groups); only that person's
    /// own record (same ID) is renamed to match the profile.
    func prepareCurrentUser(id: MemberID, displayName: String) async throws {
        let members = try context.fetch(FetchDescriptor<MemberRecord>())
        if let me = members.first(where: \.isCurrentUser) {
            guard me.id == id.rawValue, me.displayName != displayName else { return }
            me.displayName = displayName
        } else if let existing = members.first(where: { $0.id == id.rawValue }) {
            existing.isCurrentUser = true
            existing.displayName = displayName
        } else {
            context.insert(MemberRecord(id: id.rawValue, displayName: displayName, handle: nil, isCurrentUser: true))
        }
        try save()
        Log.persistence.info("Prepared this iPhone's ledger for the signed-in account")
    }
}

extension SwiftDataLedgerStore: LocalDataInspecting {
    func holdsGroupsOrExpenses() -> Bool {
        ((try? context.fetchCount(FetchDescriptor<GroupRecord>())) ?? 0) + ((try? context.fetchCount(FetchDescriptor<ExpenseRecord>())) ?? 0) > 0
    }
}
