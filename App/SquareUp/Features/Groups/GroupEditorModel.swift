import Foundation
import Observation

/// What the group editor should open.
enum GroupEditorRequest: Identifiable, Equatable {
    case create
    case edit(GroupID)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        }
    }

    /// The group being edited, if any (milestone 7: a shared group is edited on its own ledger).
    var groupID: GroupID? {
        if case .edit(let id) = self { id } else { nil }
    }
}

/// State for creating or editing a personal group. All rules are enforced by `LedgerEngine`;
/// this model only collects input and reports the engine's answer.
@Observable
final class GroupEditorModel {
    /// A person typed in while creating a group, not yet saved.
    struct PendingMember: Identifiable, Equatable {
        let id = UUID()
        var displayName: String
        var handle: String
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case failed(String)
        case saved(GroupID)
    }

    static let symbols = [
        "person.3.fill", "house.fill", "airplane", "mountain.2.fill", "fork.knife", "car.fill",
        "party.popper.fill", "sportscourt.fill", "graduationcap.fill", "tent.fill", "cart.fill", "heart.fill",
    ]
    static let currencies: [CurrencyCode] = [.usd, .eur, .gbp, CurrencyCode("CAD"), CurrencyCode("AUD"), .inr, CurrencyCode("MXN"), .jpy]

    let request: GroupEditorRequest
    /// Milestone 7: where a new group lives — shared through the server, or on this iPhone only.
    enum Location: String, CaseIterable, Identifiable {
        case shared, local
        var id: String { rawValue }
    }

    var location: Location = .local
    var name = ""
    var details = ""
    var symbolName = GroupEditorModel.symbols[0]
    var currency: CurrencyCode = .usd
    private(set) var pendingMembers: [PendingMember] = []
    var memberName = ""
    var memberHandle = ""
    private(set) var memberMessage: String?
    private(set) var saveState: SaveState = .idle
    private(set) var snapshot: LedgerSnapshot?
    private(set) var loadError: LedgerError?
    /// Set after the first save attempt so empty-field errors don't appear while typing.
    private(set) var showsValidation = false

    init(request: GroupEditorRequest) {
        self.request = request
    }

    var isCreating: Bool { request == .create }

    var group: ExpenseGroup? {
        guard case .edit(let id) = request else { return nil }
        return snapshot?.group(id)
    }

    var currentUser: Member? { snapshot?.currentUser }

    var activeMembers: [Member] {
        guard let group, let snapshot else { return [] }
        return snapshot.activeMembers(of: group)
    }

    var formerMembers: [Member] {
        guard let group, let snapshot else { return [] }
        return group.memberships.filter { !$0.isActive }.compactMap { snapshot.members[$0.memberID] }
    }

    /// People from your other groups who aren't active here — one tap to add.
    var knownPeople: [Member] {
        guard let snapshot else { return [] }
        let excluded = Set((group?.activeMemberIDs ?? []) + [snapshot.currentUserID])
        let pendingNames = Set(pendingMembers.map { $0.displayName.lowercased() })
        return snapshot.members.values
            .filter { !excluded.contains($0.id) && !pendingNames.contains($0.displayName.lowercased()) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Picked existing people (create mode).
    private(set) var pickedExisting: [MemberID] = []

    var isCurrencyLocked: Bool {
        guard let group, let snapshot else { return false }
        return LedgerEngine.hasFinancialRecords(group.id, in: snapshot)
    }

    var nameError: String? {
        guard showsValidation, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LedgerErrorMessages.text(for: .rule(.groupNameRequired))
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saveState != .saving
    }

    // MARK: Loading

    func load(from ledger: any LedgerReading) async {
        do {
            let snapshot = try await ledger.snapshot()
            apply(snapshot)
        } catch {
            loadError = error as? LedgerError ?? .unavailable
        }
    }

    /// Test and preview entry point.
    func apply(_ snapshot: LedgerSnapshot) {
        let isFirstLoad = self.snapshot == nil
        self.snapshot = snapshot
        loadError = nil
        if isFirstLoad, let group {
            name = group.name
            details = group.details ?? ""
            symbolName = group.symbolName
            currency = group.currency
        }
    }

    // MARK: Members

    func pickExisting(_ member: Member) {
        if !pickedExisting.contains(member.id) { pickedExisting.append(member.id) }
    }

    func unpickExisting(_ id: MemberID) {
        pickedExisting.removeAll { $0 == id }
    }

    var pickedMembers: [Member] { pickedExisting.compactMap { snapshot?.members[$0] } }

    /// Create mode: validates and queues the typed person. Returns false with a message if invalid.
    @discardableResult
    func queueTypedMember() -> Bool {
        let trimmed = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            memberMessage = LedgerErrorMessages.text(for: .rule(.memberNameRequired))
            return false
        }
        do {
            _ = try LedgerEngine.validatedHandle(memberHandle)
        } catch {
            memberMessage = LedgerErrorMessages.text(for: .rule(.invalidHandle))
            return false
        }
        pendingMembers.append(PendingMember(displayName: trimmed, handle: memberHandle))
        memberName = ""
        memberHandle = ""
        memberMessage = nil
        return true
    }

    func removePending(_ id: UUID) {
        pendingMembers.removeAll { $0.id == id }
    }

    /// Edit mode: adds the typed person to the saved group immediately.
    func addTypedMember(using repository: any GroupRepository) async {
        guard let group else { return }
        let trimmed = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            memberMessage = LedgerErrorMessages.text(for: .rule(.memberNameRequired))
            return
        }
        await run(repository) {
            try await repository.addMember(MemberDraft(displayName: trimmed, handle: memberHandle), to: group.id)
            memberName = ""
            memberHandle = ""
        }
    }

    func addExisting(_ member: Member, using repository: any GroupRepository) async {
        guard let group else { return }
        await run(repository) { try await repository.addExistingMember(member.id, to: group.id) }
    }

    func remove(_ member: Member, using repository: any GroupRepository) async {
        guard let group else { return }
        await run(repository) { try await repository.removeMember(member.id, from: group.id) }
    }

    private func run(_ repository: any GroupRepository, _ body: () async throws -> Void) async {
        do {
            try await body()
            memberMessage = nil
            await apply(try repository.snapshot())
        } catch {
            memberMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: snapshot?.members ?? [:])
        }
    }

    // MARK: Saving

    var draft: GroupDraft {
        GroupDraft(
            name: name, details: details, symbolName: symbolName, currency: currency,
            newMembers: pendingMembers.map { MemberDraft(displayName: $0.displayName, handle: $0.handle) },
            existingMemberIDs: pickedExisting
        )
    }

    @discardableResult
    func save(using repository: any GroupRepository, sharedGroups: SharedGroupsService? = nil) async -> GroupID? {
        showsValidation = true
        guard canSave else { return nil }
        // A name typed in the "add person" field but not yet added is almost always intended.
        if isCreating, !memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !queueTypedMember() {
            return nil
        }
        saveState = .saving
        do {
            let id: GroupID
            switch request {
            case .create where location == .shared:
                guard let sharedGroups else { throw LedgerError.remote(.notConfigured) }
                // Only the creator to start: everyone else joins with their own invitation.
                id = try await sharedGroups.createGroup(draft)
            case .create:
                id = try await repository.createGroup(draft)
            case .edit(let groupID):
                try await repository.updateGroup(groupID, with: draft)
                id = groupID
            }
            saveState = .saved(id)
            return id
        } catch {
            saveState = .failed(LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable))
            return nil
        }
    }
}
