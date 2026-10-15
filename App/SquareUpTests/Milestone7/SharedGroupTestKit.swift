import Foundation
@testable import SquareUp

/// Builders for shared-group wire snapshots (milestone 7). Balances are derived with the app's own
/// `SettlementPlanner`, exactly as the server derives them, unless a test overrides them.
enum SharedFixtures {
    static let groupID = GroupID(UUID(uuidString: "a0000000-0000-4000-8000-000000000001")!)
    static let riley = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a1")!)
    static let maya = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a2")!)
    static let dev = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a3")!)
    static let createdAt = "2026-10-01T12:00:00.000000Z"

    static func id<Tag>(_ value: Identifier<Tag>) -> String { SharedGroupMapper.id(value) }

    static func member(_ id: MemberID, _ name: String, status: String = "active", providers: [String] = []) -> GroupMemberDTO {
        GroupMemberDTO(id: SharedFixtures.id(id), displayName: name, handle: nil, status: status, hasAccount: status != "pending",
                       addedAt: createdAt, joinedAt: status == "pending" ? nil : createdAt, removedAt: status == "removed" ? createdAt : nil,
                       destinationProviders: providers)
    }

    static var members: [GroupMemberDTO] {
        [member(riley, "Riley Park", providers: ["venmo"]), member(maya, "Maya Chen"), member(dev, "Dev Kapoor", status: "pending")]
    }

    static func expense(_ id: ExpenseID = ExpenseID(), title: String = "Groceries", total: Int, payer: MemberID = riley,
                        shares: [(MemberID, Int)], method: String = "exact", revision: Int = 1, createdBy: MemberID = riley,
                        deleted: Bool = false) -> GroupExpenseDTO {
        GroupExpenseDTO(id: SharedFixtures.id(id), title: title, merchant: nil, date: "2026-10-02T19:30:00.000Z", total: total, category: "groceries",
                        splitMethod: method, payments: [ShareDTO(memberId: SharedFixtures.id(payer), amount: total)],
                        allocations: shares.map { ShareDTO(memberId: SharedFixtures.id($0.0), amount: $0.1) }, note: nil,
                        createdBy: SharedFixtures.id(createdBy), createdAt: createdAt, revision: revision, updatedAt: nil, updatedBy: nil,
                        deletedAt: deleted ? createdAt : nil, deletedBy: deleted ? SharedFixtures.id(createdBy) : nil, receipt: nil,
                        receiptOmitted: nil, roomId: nil)
    }

    static func event(_ sequence: Int, _ kind: String, actor: MemberID = riley, data: JSONValue = [:]) -> GroupEventDTO {
        GroupEventDTO(id: UUID().uuidString.lowercased(), sequence: sequence, actorMemberId: SharedFixtures.id(actor), at: createdAt, kind: kind, data: data)
    }

    static func snapshot(
        revision: Int = 3, viewer: MemberID = maya, expenses: [GroupExpenseDTO] = [], settlements: [GroupSettlementDTO] = [],
        attempts: [GroupAttemptDTO] = [], members: [GroupMemberDTO] = SharedFixtures.members, events: [GroupEventDTO]? = nil,
        archived: Bool = false, balances: GroupBalancesDTO? = nil
    ) -> GroupSnapshotDTO {
        let history = events ?? [event(1, "groupCreated", data: ["name": "Coastal Weekend"])]
        let header = GroupHeaderDTO(id: id(groupID), name: "Coastal Weekend", details: nil, symbol: "beach.umbrella.fill", currency: "USD",
                                    simplifiesDebts: true, ownerMemberId: id(riley), createdAt: createdAt, archivedAt: archived ? createdAt : nil,
                                    revision: revision, publishedFromDevice: false)
        var dto = GroupSnapshotDTO(
            schemaVersion: 1, serverTime: createdAt, revision: revision, cursor: history.last?.sequence ?? 0, group: header,
            viewer: GroupViewerDTO(memberId: id(viewer), isOwner: viewer == riley), members: members, expenses: expenses,
            settlements: settlements, attempts: attempts,
            balances: GroupBalancesDTO(simplified: true, payments: [], directPaymentCount: 0, simplifiedPaymentCount: 0, pendingAttemptIds: [],
                                       confirmedNets: [:], availableNets: [:]),
            events: history, eventsComplete: true
        )
        dto.balances = balances ?? derivedBalances(dto)
        return dto
    }

    /// What the server would send: the planner's result over the mapped records.
    static func derivedBalances(_ dto: GroupSnapshotDTO) -> GroupBalancesDTO {
        guard let workspace = try? SharedGroupMapper.workspace(dto), let group = workspace.groups.first else { return dto.balances }
        let plan = SettlementPlanner.plan(for: group, expenses: workspace.expenses(in: group.id), settlements: workspace.settlements(in: group.id),
                                          attempts: workspace.attempts(in: group.id))
        return GroupBalancesDTO(
            simplified: plan.isSimplified,
            payments: plan.payments.map { PlannedPaymentDTO(payerId: id($0.payerID), recipientId: id($0.recipientID), amount: Int($0.amount.minorUnits)) },
            directPaymentCount: plan.directPaymentCount, simplifiedPaymentCount: plan.simplifiedPaymentCount,
            pendingAttemptIds: plan.pending.map { id($0.id) },
            confirmedNets: Dictionary(uniqueKeysWithValues: plan.confirmedNets.map { (id($0.key), Int($0.value.minorUnits)) }),
            availableNets: Dictionary(uniqueKeysWithValues: plan.availableNets.map { (id($0.key), Int($0.value.minorUnits)) })
        )
    }

    static func json(_ value: some Encodable) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    static func commandResponse(applied: Bool = true, revision: Int, cursor: Int, result: JSONValue = [:], changes: GroupChangesDTO? = nil) -> Data {
        json(GroupCommandResponse(commandId: UUID().uuidString.lowercased(), applied: applied, replayed: false, revision: revision, cursor: cursor,
                                  result: result, changes: changes))
    }

    static func changes(from base: GroupSnapshotDTO, to next: GroupSnapshotDTO) -> GroupChangesDTO {
        GroupChangesDTO(schemaVersion: 1, serverTime: next.serverTime, revision: next.revision, after: base.cursor, cursor: next.cursor,
                        cursorExpired: false, group: next.group, viewer: next.viewer, members: next.members,
                        expenses: next.expenses.filter { !base.expenses.contains($0) }, settlements: next.settlements.filter { !base.settlements.contains($0) },
                        attempts: next.attempts.filter { !base.attempts.contains($0) }, balances: next.balances,
                        events: next.events.filter { $0.sequence > base.cursor })
    }

    static func refusal(_ status: Int, _ code: String, extra: [String: JSONValue] = [:]) -> Data {
        var error: [String: JSONValue] = ["code": .string(code), "message": "Refused", "requestId": "test"]
        error.merge(extra) { _, new in new }
        return json(JSONValue.object(["error": .object(error)]))
    }

    /// A configured API against a scripted transport, with a development account (recoverable).
    static func api(_ transport: ScriptedTransport) -> SharedGroupAPI {
        let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:9", authMode: "development", firebaseAPIKey: nil)!
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.shared.\(UUID())"))
        return SharedGroupAPI(configuration: configuration, transport: transport, account: account)
    }

    @MainActor
    static func ledger(_ transport: ScriptedTransport, initial: GroupSnapshotDTO? = nil, cache: SharedGroupCache = SharedGroupCache(root: nil),
                       account: String = "account-a") -> SharedGroupLedger {
        SharedGroupLedger(groupID: groupID, account: account, api: api(transport), cache: cache, profile: { nil }, initial: initial)
    }

    static func path(_ request: URLRequest) -> String { request.url?.path() ?? "" }

    static func body(_ request: URLRequest) -> JSONValue? {
        request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}
