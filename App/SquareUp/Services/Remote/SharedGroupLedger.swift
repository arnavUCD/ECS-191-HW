import Foundation
import Observation
import OSLog

/// One shared group, presented through the same `LedgerStore` interface every group screen uses
/// (milestone 7 §7.1). The server is authoritative; this is its protected local view.
///
/// - `base` is the last snapshot the server confirmed, exactly as sent, cached per account
///   (`SharedGroupCache`) so the group stays readable offline. `snapshot()` maps it to a
///   workspace (`SharedGroupMapper.workspace`) with this account's seat as the current user.
/// - Commands are checked by the same `LedgerEngine` first (instant, specific errors; nothing is
///   sent if they fail), then sent with a stable command ID, idempotency key, and the client's
///   cursor. Retries resend the identical envelope, so nothing is ever applied twice.
/// - Ordinary expense edits may preview at once, marked pending. Balances, settlements,
///   membership, and payment confirmations are never shown before the server confirms them.
///   High-consequence commands (§7.4) need a live answer and are never queued offline.
/// - Each new server state is verified before it's shown: the app recomputes balances and the
///   plan and compares them with the server's. A mismatch keeps the last good state (§14).
/// - Polling runs only while a screen asks for it and the app is active: quickly while someone is
///   collaborating or a payment is waiting, slowly otherwise, backing off after failures.
@Observable
final class SharedGroupLedger: LedgerStore {
    nonisolated enum SyncState: Equatable, Sendable {
        case loading
        case synced(Date)
        /// Showing the saved copy (from this date) while checking for changes.
        case refreshing(Date?)
        case sending(Int)
        /// Couldn't reach the server; showing the copy from this date.
        case offline(lastSynced: Date?)
        /// The sign-in expired; drafts and waiting changes are kept until signing in again.
        case sessionEnded
        /// This account is no longer in the group (removed or left), or it no longer exists.
        case accessEnded
    }

    nonisolated enum Notice: Equatable, Sendable {
        /// Someone changed the group first; the latest is showing. `retryable` can be tried again.
        case conflict(summary: String)
        /// Someone changed this expense; the draft is kept so it can be reviewed and retried.
        case expenseChanged(ExpenseID)
        /// A change that waited for the connection was refused when it was finally sent.
        case refused(summary: String, message: String)
        /// The server's latest state couldn't be read or didn't add up here; the last good state stays.
        case unreadable
        /// A high-consequence action needs a connection; nothing is confirmed yet.
        case connectionRequired(summary: String)
    }

    private(set) var revision = 0
    private(set) var syncState: SyncState = .loading
    private(set) var base: GroupSnapshotDTO?
    private(set) var notice: Notice?
    private(set) var unsent: [SharedGroupCache.UnsentChange] = []
    /// Expenses previewed but not yet confirmed by the server.
    private(set) var pendingExpenseIDs: Set<ExpenseID> = []
    /// A high-consequence change whose outcome is unknown; "Try again" resends it unchanged.
    private(set) var unconfirmed: (envelope: GroupCommandEnvelope, summary: String)?
    private(set) var lastSynced: Date?

    @ObservationIgnored let groupID: GroupID
    @ObservationIgnored let account: String
    @ObservationIgnored let api: SharedGroupAPI
    @ObservationIgnored private let cache: SharedGroupCache
    @ObservationIgnored private let profile: () -> ProfileDTO?
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var rooms: [ReceiptRoom] = []
    @ObservationIgnored var revealed: [MemberID: [PaymentDestination]] = [:]
    /// Live sessions for this group's receipts (kept while the app runs, so reopening is instant).
    @ObservationIgnored var receiptSessions: [ReceiptRoomID: RemoteRoomLedger] = [:]
    @ObservationIgnored private var display: LedgerSnapshot?
    @ObservationIgnored private var previews: [(id: UUID, command: LedgerCommand)] = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var collaborators = 0
    @ObservationIgnored var inFlight = 0
    /// Called after every accepted server state (Home and the group list refresh their summaries).
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored var fastPollInterval: Duration = .seconds(3)
    @ObservationIgnored var slowPollInterval: Duration = .seconds(20)
    @ObservationIgnored var maximumBackoff: Duration = .seconds(60)

    init(groupID: GroupID, account: String, api: SharedGroupAPI, cache: SharedGroupCache, profile: @escaping () -> ProfileDTO?,
         initial: GroupSnapshotDTO? = nil, now: @escaping () -> Date = { .now }) {
        self.groupID = groupID
        self.account = account
        self.api = api
        self.cache = cache
        self.profile = profile
        self.now = now
        if let entry = cache.group(groupID, account: account) {
            base = entry.snapshot
            unsent = entry.unsent
            rooms = entry.rooms
            lastSynced = entry.cachedAt
            syncState = .refreshing(entry.cachedAt)
        }
        if let initial, initial.revision >= (base?.revision ?? 0) {
            base = initial
            lastSynced = now()
            syncState = .synced(now())
            persist()
        }
        rebuild()
    }

    var viewerID: MemberID? { base.flatMap { MemberID(string: $0.viewer.memberId) } }
    var isOwner: Bool { base?.viewer.isOwner ?? false }
    var isArchived: Bool { base?.group.archivedAt != nil }
    var groupName: String { base?.group.name ?? "" }
    var ownerID: MemberID? { base.flatMap { MemberID(string: $0.group.ownerMemberId) } }

    /// `active`, `pending` (a seat waiting for its person to join), or `removed`.
    func status(of member: MemberID) -> String? {
        base?.members.first { $0.id == SharedGroupMapper.id(member) }?.status
    }

    /// The payment methods a member accepts, by name only (identifiers are revealed separately).
    func providers(of member: MemberID) -> [PaymentProviderKind] {
        (base?.members.first { $0.id == SharedGroupMapper.id(member) }?.destinationProviders ?? []).compactMap(PaymentProviderKind.init(rawValue:))
    }

    // MARK: - LedgerReading

    func snapshot() async throws -> LedgerSnapshot {
        if display == nil {
            if base == nil { try await refresh() } else { rebuild() }
        }
        guard let display else { throw LedgerError.remote(.unavailable) }
        return display
    }

    // MARK: - Commands

    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult {
        if let actor, actor != viewerID {
            throw LedgerError.remote(.refused(String(localized: "In a shared group, everyone acts as themselves.")))
        }
        switch command {
        case .receipt(let roomCommand):
            return try await enqueue { try await self.performReceipt(roomCommand) }
        case .saveDestination, .deleteDestination:
            throw LedgerError.remote(.refused(String(localized: "Your payment methods are in Profile.")))
        case .recordSettlement(let settlement) where settlement.toID == viewerID:
            // "Mark as settled": the person owed records it; the server caps it at what's owed now.
            return try await enqueue { try await self.send(command) }
        case .recordSettlement:
            throw LedgerError.remote(.refused(String(localized: "In a shared group, only the person who's owed can mark it as settled.")))
        case .createGroup, .addExistingMember, .switchCurrentUser:
            throw LedgerError.remote(.refused(String(localized: "That isn't available in a shared group.")))
        default:
            return try await enqueue { try await self.send(command) }
        }
    }

    /// Runs commands one at a time, in order (also used by `SharedGroupLedger+Actions`).
    func enqueue<T: Sendable>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private static let optimisticTypes: Set<String> = ["addExpense", "updateExpense", "deleteExpense", "restoreExpense"]

    private func send(_ command: LedgerCommand) async throws -> LedgerCommandResult {
        let workspace = try await snapshot()
        guard let viewer = viewerID, let current = base else { throw LedgerError.remote(.unavailable) }
        if isArchived { throw LedgerError.remote(.refused(String(localized: "This group was archived."))) }
        // The same engine first: specific, immediate errors, and nothing is sent if it fails.
        let local = try LedgerEngine.perform(command, on: workspace, actor: viewer, now: now())
        let wire: SharedGroupMapper.WireCommand
        do {
            wire = try SharedGroupMapper.command(command, in: workspace)
        } catch {
            throw LedgerError.remote(.refused(String(localized: "That isn't available in a shared group.")))
        }
        let envelope = GroupCommandEnvelope(type: wire.type, payload: wire.payload, expectedRevision: current.revision, knownCursor: current.cursor)
        let summary = Self.summary(of: command, in: workspace)
        let previewID = Self.optimisticTypes.contains(wire.type) ? addPreview(command) : nil
        return try await deliverAndAccept(envelope, wire: wire, command: command, summary: summary, local: local, previewID: previewID)
    }

    func deliverAndAccept(
        _ envelope: GroupCommandEnvelope, wire: SharedGroupMapper.WireCommand?, command: LedgerCommand?, summary: String,
        local: LedgerCommandResult?, previewID: UUID?
    ) async throws -> LedgerCommandResult {
        inFlight += 1
        syncState = .sending(max(previews.count, 1))
        defer { inFlight -= 1 }
        let response: GroupCommandResponse
        do {
            response = try await deliver(envelope)
        } catch {
            try await handle(error, envelope: envelope, live: wire?.requiresLiveResponse ?? true, summary: summary, previewID: previewID,
                             command: command)
        }
        dropPreview(previewID)
        if unconfirmed?.envelope.idempotencyKey == envelope.idempotencyKey { unconfirmed = nil }
        notice = nil
        await accept(response)
        Log.sync.info("Group command \(envelope.type, privacy: .public) \(response.applied ? "applied" : "unchanged", privacy: .public)")
        return result(for: response, wire: wire, local: local)
    }

    /// The result in the app's terms, built from the confirmed state.
    private func result(for response: GroupCommandResponse, wire: SharedGroupMapper.WireCommand?, local: LedgerCommandResult?) -> LedgerCommandResult {
        var result = LedgerCommandResult()
        result.groupID = groupID
        if let memberID = wire?.newMemberID { result.memberIDs = [memberID] }
        let attemptID = response.result["attemptId"]?.stringValue.flatMap(PaymentAttemptID.init(string:)) ?? wire?.newAttemptID
        if let attemptID { result.attempt = display?.attempt(attemptID) }
        if let settlementID = response.result["settlementId"]?.stringValue.flatMap(SettlementID.init(string:)) {
            result.settlement = display?.settlements.first { $0.id == settlementID }
        }
        result.expenseID = response.result["expenseId"]?.stringValue.flatMap(ExpenseID.init(string:)) ?? local?.expenseID
        result.room = local?.room
        // A non-empty change list tells callers the command took effect.
        if response.applied || response.replayed { result.changes = local?.changes ?? [] }
        return result
    }

    /// Sends with up to two automatic retries of the *same* envelope when the outcome is unknown.
    private func deliver(_ envelope: GroupCommandEnvelope) async throws(RemoteError) -> GroupCommandResponse {
        var attempt = 0
        while true {
            do {
                return try await api.command(envelope, group: SharedGroupMapper.id(groupID))
            } catch {
                guard error.isRetryable, attempt < 2 else { throw error }
                attempt += 1
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 500 : 1500))
            }
        }
    }

    private func handle(
        _ error: RemoteError, envelope: GroupCommandEnvelope, live: Bool, summary: String, previewID: UUID?, command: LedgerCommand?
    ) async throws -> Never {
        if error.isRetryable {
            // The outcome is unknown (no connection, a timeout, or the server was busy).
            syncState = .offline(lastSynced: lastSynced)
            if live {
                // Never queued: the person decides whether to try again (same key, so at most once).
                dropPreview(previewID)
                unconfirmed = (envelope, summary)
                notice = .connectionRequired(summary: summary)
                throw LedgerError.remote(.connectionRequired)
            }
            // Waiting for connection: kept (and its preview) until it can be sent with the same key.
            if !unsent.contains(where: { $0.envelope.idempotencyKey == envelope.idempotencyKey }) {
                unsent.append(SharedGroupCache.UnsentChange(envelope: envelope, summary: summary, queuedAt: now()))
                persist()
            }
            throw LedgerError.remote(.offline)
        }
        switch error {
        case .offline, .timedOut:
            throw LedgerError.remote(.offline) // unreachable: retryable
        case .unexpected:
            dropPreview(previewID)
            throw LedgerError.remote(.unavailable)
        case .notConfigured:
            dropPreview(previewID)
            throw LedgerError.remote(.notConfigured)
        case .account(let failure):
            dropPreview(previewID)
            if failure == .sessionEnded || failure == .notConfigured { syncState = .sessionEnded }
            throw LedgerError.remote(.signInFailed(failure))
        case .server(let refusal):
            dropPreview(previewID)
            switch refusal.code {
            case "unauthenticated":
                syncState = .sessionEnded
                throw LedgerError.remote(.signInFailed(.sessionEnded))
            case "not_a_member", "group_not_found":
                endAccess()
                throw LedgerError.remote(.removedFromGroup)
            case "revision_conflict":
                try? await refresh()
                notice = .conflict(summary: summary)
                throw LedgerError.remote(.conflict)
            case "expense_conflict":
                try? await refresh()
                if let id = command.flatMap(Self.expenseID) { notice = .expenseChanged(id) }
                throw LedgerError.remote(.conflict)
            default:
                if ["pending_payment_conflict", "exceeds_obligation", "no_obligation", "member_has_balance"].contains(refusal.code) {
                    try? await refresh()
                }
                syncState = lastSynced.map(SyncState.synced) ?? .loading
                throw LedgerError.from(group: refusal, currency: base.map { CurrencyCode($0.group.currency) } ?? .usd)
            }
        }
    }

    /// Resends every change that waited for the connection, in order, each with its original key.
    func resendUnsent() async {
        for change in unsent where change.refusal == nil {
            do {
                _ = try await enqueue { try await self.deliverAndAccept(change.envelope, wire: nil, command: nil, summary: change.summary,
                                                                        local: nil, previewID: nil) }
                unsent.removeAll { $0.id == change.id }
                persist()
            } catch LedgerError.remote(.offline) {
                return
            } catch {
                if let index = unsent.firstIndex(where: { $0.id == change.id }) {
                    unsent[index].refusal = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
                    notice = .refused(summary: change.summary, message: unsent[index].refusal ?? "")
                    persist()
                }
            }
        }
        if unsent.isEmpty { clearPreviews() }
    }

    /// Discards a waiting change the server refused (or that the person no longer wants).
    func discard(_ change: SharedGroupCache.UnsentChange) {
        unsent.removeAll { $0.id == change.id }
        if unsent.isEmpty { clearPreviews() }
        if case .refused = notice { notice = nil }
        persist()
        rebuild()
    }

    /// Sends a high-consequence change again with the same key (after "connection required").
    func retryUnconfirmed() async throws {
        guard let unconfirmed else { return }
        _ = try await enqueue {
            try await self.deliverAndAccept(unconfirmed.envelope, wire: nil, command: nil, summary: unconfirmed.summary, local: nil, previewID: nil)
        }
    }

    func dismissNotice() {
        if case .connectionRequired = notice { unconfirmed = nil }
        notice = nil
    }

    // MARK: - Refresh and polling (§7.3)

    /// Fetches what changed since the cursor (or a full snapshot when that can't be applied safely).
    func refresh() async throws {
        syncState = base == nil ? .loading : .refreshing(lastSynced)
        do throws(RemoteError) {
            if let current = base {
                let changes = try await api.changes(SharedGroupMapper.id(groupID), after: current.cursor)
                if let next = SharedGroupMapper.applying(changes, to: current) {
                    if !adopt(next) { try await fullSnapshot() }
                } else if changes.cursor == current.cursor, !changes.cursorExpired, changes.events?.isEmpty ?? true {
                    markSynced()
                } else {
                    try await fullSnapshot()
                }
            } else {
                try await fullSnapshot()
            }
        } catch {
            switch error {
            case .offline, .timedOut:
                syncState = .offline(lastSynced: lastSynced)
                throw LedgerError.remote(.offline)
            case .server(let refusal) where ["not_a_member", "group_not_found"].contains(refusal.code):
                endAccess()
                throw LedgerError.remote(.removedFromGroup)
            case .server(let refusal) where refusal.code == "unauthenticated":
                syncState = .sessionEnded
                throw LedgerError.remote(.signInFailed(.sessionEnded))
            case .account(let failure):
                syncState = failure == .offline ? .offline(lastSynced: lastSynced) : .sessionEnded
                throw LedgerError.remote(failure == .offline ? .offline : .signInFailed(failure))
            default:
                syncState = .offline(lastSynced: lastSynced)
                throw LedgerError.remote(.unavailable)
            }
        }
        if unsent.contains(where: { $0.refusal == nil }) { await resendUnsent() }
    }

    private func fullSnapshot() async throws(RemoteError) {
        let snapshot = try await api.snapshot(SharedGroupMapper.id(groupID))
        if !adopt(snapshot) {
            notice = .unreadable
            syncState = .synced(lastSynced ?? now())
        }
    }

    private func endAccess() {
        syncState = .accessEnded
        stopPolling()
    }

    // MARK: - Accepting server state

    func accept(_ response: GroupCommandResponse) async {
        if let changes = response.changes, let current = base, let next = SharedGroupMapper.applying(changes, to: current), adopt(next) {
            return
        }
        try? await fullSnapshot()
    }

    /// Verifies and shows a new authoritative state. Returns false (and changes nothing) when it
    /// can't be mapped or its balances don't match the app's own calculation.
    @discardableResult
    private func adopt(_ next: GroupSnapshotDTO) -> Bool {
        if let current = base, next.revision < current.revision { return true } // never go back in time
        do {
            let workspace = try SharedGroupMapper.workspace(next, destinations: destinations(for: next), rooms: rooms)
            guard SharedGroupMapper.balancesAgree(workspace, server: next.balances) else { throw SharedGroupMapper.Failure.balancesDiffer }
        } catch {
            Log.sync.error("A shared group's latest state didn't verify (\(String(describing: error), privacy: .public)); keeping the last good one")
            return false
        }
        base = next
        if next.group.archivedAt != nil || next.members.first(where: { $0.id == next.viewer.memberId })?.status == "removed" {
            stopPolling()
        }
        markSynced()
        persist()
        rebuild()
        didChange?()
        return true
    }

    private func markSynced() {
        lastSynced = now()
        if syncState != .accessEnded, inFlight == 0 || previews.isEmpty { syncState = .synced(lastSynced ?? now()) }
    }

    private func destinations(for snapshot: GroupSnapshotDTO) -> [PaymentDestination] {
        let own = MemberID(string: snapshot.viewer.memberId).map { viewer in
            (profile()?.destinations ?? []).compactMap { SharedGroupMapper.destination($0, owner: viewer) }
        } ?? []
        return own + revealed.values.flatMap { $0 }
    }

    func persist() {
        guard let base else { return }
        cache.save(SharedGroupCache.GroupEntry(snapshot: base, cachedAt: lastSynced ?? now(), unsent: unsent, rooms: rooms), group: groupID, account: account)
    }

    // MARK: - Optimistic previews

    private func addPreview(_ command: LedgerCommand) -> UUID {
        let id = UUID()
        previews.append((id, command))
        if let expenseID = Self.expenseID(command) { pendingExpenseIDs.insert(expenseID) }
        rebuild()
        return id
    }

    /// Removes a preview once the server answered. (A change waiting for the connection keeps its
    /// preview: its path never calls this, and `clearPreviews` runs once everything was sent.)
    private func dropPreview(_ id: UUID?) {
        guard let id else { return }
        previews.removeAll { $0.id == id }
        pendingExpenseIDs = Set(previews.compactMap { Self.expenseID($0.command) })
        rebuild()
    }

    private func clearPreviews() {
        previews.removeAll()
        pendingExpenseIDs = []
        rebuild()
    }

    static func expenseID(_ command: LedgerCommand) -> ExpenseID? {
        switch command {
        case .addExpense(let expense), .updateExpense(let expense): expense.id
        case .deleteExpense(let id), .restoreExpense(let id): id
        default: nil
        }
    }

    func rebuild() {
        guard let base else { return }
        guard var workspace = try? SharedGroupMapper.workspace(base, destinations: destinations(for: base), rooms: rooms) else {
            notice = .unreadable
            return
        }
        if let viewer = viewerID {
            for (_, command) in previews {
                guard let result = try? LedgerEngine.perform(command, on: workspace, actor: viewer, now: now()) else { continue }
                workspace = LedgerEngine.apply(result.changes, to: workspace)
            }
        }
        display = workspace
        revision += 1
    }

    // MARK: - Unsupported ledger operations

    func resetToSampleData(referenceDate: Date) async throws { throw LedgerError.unavailable }
    func eraseAll() async throws { throw LedgerError.unavailable }
}
