import Foundation
import Observation
import OSLog

/// One shared Receipt Room, presented through the same `LedgerStore` interface the room screens
/// already use (milestone 4 §4.3 "remote `ReceiptRoomRepository`"). The server is authoritative:
///
/// - `snapshot()` is a workspace built from the latest server snapshot (see
///   `RemoteRoomMapper.workspace`), with this person's unconfirmed changes previewed on top.
/// - `perform` sends the room command to the server with a command ID, an idempotency key, and
///   the revision it was based on, and returns only after the server accepts or refuses it.
///   Optimistic previews are marked pending (`pendingItemIDs`, `syncState`) and removed on any
///   outcome — a financial change never looks confirmed before the server confirms it.
/// - Commands run one at a time. A person's own quick taps never conflict with each other:
///   a command based on a revision that only this device has advanced since is rebased.
/// - A stale revision is refused by the server without partial application; the latest room
///   replaces the preview and `notice` explains what happened (§7.2).
/// - Polling (§7.3) runs only while the room is on screen and the app is active, never overlaps a
///   command, backs off after failures, and stops once the room is finalized, cancelled, or
///   this person's access has ended.
@Observable
final class RemoteRoomLedger: LedgerStore {
    nonisolated enum SyncState: Equatable, Sendable {
        case connecting
        case synced(Date)
        /// Changes waiting for the server.
        case sending(Int)
        /// Showing the last snapshot from this date; nothing new can be confirmed.
        case offline(lastSynced: Date?)
        /// The invitation expired or was revoked, or the host removed this person.
        case accessEnded
    }

    /// Why the latest room replaced what this person was looking at.
    nonisolated struct Notice: Sendable {
        let issue: RemoteIssue
        /// The change that didn't go through, so it can be tried again on the latest room.
        let retryable: ReceiptRoomCommand?
    }

    /// Context from the device that owns this view of the room (host or participant).
    struct Hooks {
        /// The host's local ledger, room, and group for this room (`nil` for participants).
        var local: () async -> Local = { Local() }
        /// Called with every new authoritative snapshot; returns the local expense once the
        /// host's device has saved the finalized room.
        var didChange: (RoomDTO) async -> ExpenseID? = { _ in nil }
        /// Checked before finalizing; an issue stops the request before it is sent.
        var finalizeBlocker: (RoomDTO) -> RemoteIssue? = { _ in nil }
    }

    nonisolated struct Local: Sendable {
        var snapshot: LedgerSnapshot?
        var room: ReceiptRoom?
        var groupName: String?
        var finalExpenseID: ExpenseID?
    }

    private(set) var revision = 0
    private(set) var syncState: SyncState = .connecting
    private(set) var base: RoomDTO?
    private(set) var pendingItemIDs: Set<ReceiptItemID> = []
    private(set) var notice: Notice?
    /// A change that couldn't reach the server; resending reuses its idempotency key.
    private(set) var unsent: (command: ReceiptRoomCommand, envelope: CommandEnvelope)?

    @ObservationIgnored let roomID: ReceiptRoomID
    @ObservationIgnored let caller: RemoteCaller
    @ObservationIgnored private let channel: any RoomChannel
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var display: LedgerSnapshot?
    @ObservationIgnored private var optimistic: [(id: UUID, command: ReceiptRoomCommand)] = []
    @ObservationIgnored private var ownRevisions: Set<Int> = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var lastSynced: Date?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastExpenseID: ExpenseID?
    /// Seconds between polls while the room is active (overridable for tests).
    @ObservationIgnored var pollInterval: Duration = .seconds(3)
    @ObservationIgnored var maximumBackoff: Duration = .seconds(30)

    convenience init(roomID: ReceiptRoomID, caller: RemoteCaller, api: RoomAPIClient, hooks: Hooks = Hooks(), now: @escaping () -> Date = { .now }) {
        self.init(roomID: roomID, caller: caller, channel: RoomAPIChannel(api: api, roomID: roomID, caller: caller), hooks: hooks, now: now)
    }

    init(roomID: ReceiptRoomID, caller: RemoteCaller = .account, channel: any RoomChannel, hooks: Hooks = Hooks(), now: @escaping () -> Date = { .now }) {
        self.roomID = roomID
        self.caller = caller
        self.channel = channel
        self.hooks = hooks
        self.now = now
    }

    var viewerID: MemberID? { base.map { RemoteRoomMapper.member($0.viewer.participantId) } }
    var isHost: Bool { base?.viewer.isHost ?? false }
    var isPolling: Bool { pollTask != nil }
    /// "Split with people now": no group; guests settle up with the payer inside the room.
    var isTemporary: Bool { base?.isTemporary ?? false }
    /// A receipt posted into a shared group (no invitations, guests, or live room).
    var isGroupReceipt: Bool { base?.isGroupReceipt ?? false }

    // MARK: - LedgerReading

    func snapshot() async throws -> LedgerSnapshot {
        if display == nil { try await refresh() }
        guard let display else { throw LedgerError.remote(.unavailable) }
        return display
    }

    // MARK: - Commands

    @discardableResult
    func perform(_ command: LedgerCommand, as actor: MemberID?) async throws -> LedgerCommandResult {
        guard case .receipt(let roomCommand) = command, roomCommand.roomID == roomID else {
            throw LedgerError.remote(.refused(String(localized: "That isn't available in a shared room.")))
        }
        // The preview appears at once, even while an earlier change is still being sent.
        let previewID = await preview(roomCommand)
        return try await enqueue { try await self.send(roomCommand, previewID: previewID) }
    }

    private func preview(_ command: ReceiptRoomCommand) async -> UUID? {
        guard let type = try? RemoteRoomMapper.command(command).type, Self.optimisticTypes.contains(type), base != nil else { return nil }
        let id = UUID()
        optimistic.append((id, command))
        if let item = Self.itemID(of: command) { pendingItemIDs.insert(item) }
        syncState = .sending(optimistic.count)
        await rebuild()
        return id
    }

    /// Tries the change that couldn't reach the server again, with the same idempotency key, so it
    /// is applied at most once even if the first attempt actually arrived.
    func resendUnsent() async throws {
        guard let unsent else { return }
        _ = try await enqueue { try await self.send(unsent.command, envelope: unsent.envelope) }
    }

    /// Re-applies the change refused by a conflict against the latest revision (§7.2 step 5).
    func retryAfterConflict() async throws {
        guard let command = notice?.retryable, let base else { return }
        notice = nil
        _ = try await enqueue { try await self.send(command.rebased(to: base.revision)) }
    }

    func dismissNotice() {
        notice = nil
    }

    private func enqueue<T: Sendable>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private static let optimisticTypes: Set<String> = [
        "claim", "unclaim", "setItemSplit", "markReviewed", "dispute", "resolveDispute", "setChargeAllocation", "setPayerAcceptsFullReceipt",
    ]

    private func send(_ command: ReceiptRoomCommand, envelope existing: CommandEnvelope? = nil, previewID: UUID? = nil,
                      resends: Int = 0) async throws -> LedgerCommandResult {
        defer { dropPreview(previewID) }
        if base == nil { try await refresh() }
        guard let current = base else { throw LedgerError.remote(.unavailable) }
        let translated: (type: String, payload: JSONValue)
        do {
            translated = try RemoteRoomMapper.command(command)
        } catch {
            throw LedgerError.remote(.refused(String(localized: "That isn't available in a shared room.")))
        }
        if translated.type == "finalize", let blocker = hooks.finalizeBlocker(current) {
            throw LedgerError.remote(blocker)
        }
        let envelope = existing ?? CommandEnvelope(type: translated.type, payload: translated.payload,
                                                   expectedRevision: rebase(command.expectedRevision ?? current.revision))
        inFlight += 1
        syncState = .sending(max(optimistic.count, 1))
        defer { inFlight -= 1 }

        let response: CommandResponse
        do {
            response = try await deliver(envelope)
        } catch {
            dropPreview(previewID)
            // Someone else changed the room first, but nothing that touches this item: the claim
            // means exactly the same on the latest room, so it's sent again (a new request; the
            // refused one was never applied). A claim on an item that did change needs the
            // person's eyes, so that one stops with an explanation.
            if resends < 2, case .server(let refusal) = error, refusal.code == "revision_conflict", let latest = refusal.room,
               Self.meansTheSame(command, before: current, latest: latest) {
                _ = await accept(latest)
                return try await send(command.rebased(to: latest.revision), resends: resends + 1)
            }
            try await handle(error, for: command, envelope: envelope)
        }
        dropPreview(previewID)
        if response.applied { ownRevisions.insert(response.revision) }
        if existing != nil { unsent = nil }
        notice = nil
        let expenseID = await accept(response.room)
        Log.sync.info("Command \(envelope.type, privacy: .public) \(response.applied ? "applied" : "unchanged", privacy: .public) at revision \(response.revision, privacy: .public)")
        var result = LedgerCommandResult()
        result.room = display?.room(roomID)
        result.expenseID = expenseID
        return result
    }

    /// The item a claim (whole or by units) was for.
    nonisolated static func claimedItem(_ command: ReceiptRoomCommand) -> ReceiptItemID? {
        switch command {
        case .claim(_, _, let item, _), .claimUnits(_, _, let item, _): item
        default: nil
        }
    }

    /// Whether a claim built on `before` means exactly the same on `latest`: the same item, with the
    /// same claims by everyone, in a state that still takes claims. Only one's own claims qualify.
    static func meansTheSame(_ command: ReceiptRoomCommand, before: RoomDTO, latest: RoomDTO) -> Bool {
        let item: ReceiptItemID
        switch command {
        case .claim(_, _, let id, _), .unclaim(_, _, let id), .claimUnits(_, _, let id, _): item = id
        default: return false
        }
        let key = RemoteRoomMapper.id(item)
        func claims(_ room: RoomDTO) -> Set<ClaimDTO> { Set(room.claims.filter { $0.itemId == key }) }
        func line(_ room: RoomDTO) -> ItemDTO? { room.receipt.items.first { $0.id == key } }
        return before.state == latest.state && claims(before) == claims(latest) && line(before) == line(latest)
            && before.participantOrder == latest.participantOrder
    }

    // MARK: - Remote-only steps (temporary rooms)

    /// A step that exists only on the server: settling up in a temporary room (report, confirm,
    /// reject, dispute, or cancel a payment). Same envelope, retries, and conflict handling as any
    /// change; nothing is previewed — a payment never looks reported or confirmed early.
    @discardableResult
    func sendRemote(_ type: String, _ payload: JSONValue) async throws -> LedgerCommandResult {
        try await enqueue { try await self.sendRaw(type, payload, resends: 0) }
    }

    private func sendRaw(_ type: String, _ payload: JSONValue, resends: Int) async throws -> LedgerCommandResult {
        if base == nil { try await refresh() }
        guard let current = base else { throw LedgerError.remote(.unavailable) }
        let envelope = CommandEnvelope(type: type, payload: payload, expectedRevision: current.revision)
        inFlight += 1
        syncState = .sending(1)
        defer { inFlight -= 1 }
        let response: CommandResponse
        do {
            response = try await deliver(envelope)
        } catch {
            // Each payment step acts on one person's payment, whose own rules refuse anything that
            // no longer applies; a newer room just means trying again on it.
            if resends < 2, case .server(let refusal) = error, refusal.code == "revision_conflict", let latest = refusal.room {
                _ = await accept(latest)
                return try await sendRaw(type, payload, resends: resends + 1)
            }
            switch error {
            case .offline, .timedOut:
                syncState = .offline(lastSynced: lastSynced)
                throw LedgerError.remote(.offline)
            case .server(let refusal):
                if let room = refusal.room { _ = await accept(room) } else { syncState = lastSynced.map(SyncState.synced) ?? .connecting }
                if Self.accessEndedCodes.contains(refusal.code) {
                    endAccess()
                    throw LedgerError.remote(.accessEnded)
                }
                throw LedgerError.from(refusal, command: nil, room: base)
            case .account(let failure):
                syncState = lastSynced.map(SyncState.synced) ?? .connecting
                throw LedgerError.remote(.signInFailed(failure))
            case .notConfigured:
                throw LedgerError.remote(.notConfigured)
            case .unexpected:
                syncState = lastSynced.map(SyncState.synced) ?? .connecting
                throw LedgerError.remote(.unavailable)
            }
        }
        if response.applied { ownRevisions.insert(response.revision) }
        notice = nil
        let expenseID = await accept(response.room)
        Log.sync.info("Command \(type, privacy: .public) \(response.applied ? "applied" : "unchanged", privacy: .public)")
        var result = LedgerCommandResult()
        result.room = display?.room(roomID)
        result.expenseID = expenseID
        return result
    }

    /// Removes a preview before the authoritative result is shown (the next rebuild omits it).
    private func dropPreview(_ id: UUID?) {
        if let id { optimistic.removeAll { $0.id == id } }
        pendingItemIDs = Set(optimistic.compactMap { Self.itemID(of: $0.command) })
    }

    /// Sends with up to two automatic retries of the *same* envelope when the outcome is unknown.
    private func deliver(_ envelope: CommandEnvelope) async throws(RemoteError) -> CommandResponse {
        var attempt = 0
        while true {
            do {
                return try await channel.command(envelope)
            } catch {
                guard error.isRetryable, attempt < 2 else { throw error }
                attempt += 1
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 500 : 1500))
            }
        }
    }

    private func handle(_ error: RemoteError, for command: ReceiptRoomCommand, envelope: CommandEnvelope) async throws -> Never {
        switch error {
        case .offline, .timedOut:
            unsent = (command, envelope)
            syncState = .offline(lastSynced: lastSynced)
            await rebuild()
            throw LedgerError.remote(.offline)
        case .notConfigured:
            await rebuild()
            throw LedgerError.remote(.notConfigured)
        case .account(let failure):
            syncState = lastSynced.map(SyncState.synced) ?? .connecting
            await rebuild()
            throw LedgerError.remote(.signInFailed(failure))
        case .unexpected:
            syncState = lastSynced.map(SyncState.synced) ?? .connecting
            await rebuild()
            throw LedgerError.remote(.unavailable)
        case .server(let refusal):
            if let room = refusal.room {
                _ = await accept(room)
            } else {
                syncState = lastSynced.map(SyncState.synced) ?? .connecting
                await rebuild()
            }
            if Self.accessEndedCodes.contains(refusal.code) {
                endAccess()
                throw LedgerError.remote(.accessEnded)
            }
            if refusal.code == "revision_conflict" {
                if refusal.room == nil { try? await refresh() }
                notice = Notice(issue: .conflict, retryable: command)
                throw LedgerError.remote(.conflict)
            }
            throw LedgerError.from(refusal, command: command, room: base)
        }
    }

    /// Rebases a revision past changes only this device made since (own quick taps never collide).
    private func rebase(_ expected: Int) -> Int {
        var revision = expected
        while ownRevisions.contains(revision + 1) { revision += 1 }
        return revision
    }

    private static func itemID(of command: ReceiptRoomCommand) -> ReceiptItemID? {
        switch command {
        case .claim(_, _, let item, _), .unclaim(_, _, let item), .claimUnits(_, _, let item, _), .setItemSplit(_, _, let item, _): item
        case .dispute(_, _, .item(let item), _): item
        default: nil
        }
    }

    private static let accessEndedCodes: Set<String> = [
        "credential_expired", "not_a_participant", "room_not_found", "unauthenticated", "invitation_expired", "invitation_revoked",
        // A group receipt: the person left the group, or the receipt is no longer theirs to see.
        "not_a_member", "group_not_found", "receipt_not_found",
    ]

    // MARK: - Refresh and polling

    /// Fetches the latest room once.
    func refresh() async throws {
        do {
            let room = try await channel.room()
            if room != base || display == nil || (room.isTerminal && lastExpenseID == nil && isHost) {
                _ = await accept(room)
            } else {
                // Unchanged: just record that it is current (no redraw every poll).
                lastSynced = now()
                if optimistic.isEmpty, inFlight == 0 { syncState = .synced(lastSynced ?? now()) }
            }
        } catch {
            switch error {
            case .offline, .timedOut:
                syncState = .offline(lastSynced: lastSynced)
                throw LedgerError.remote(.offline)
            case .server(let refusal) where Self.accessEndedCodes.contains(refusal.code):
                endAccess()
                throw LedgerError.remote(.accessEnded)
            case .account(let failure):
                throw LedgerError.remote(.signInFailed(failure))
            case .notConfigured:
                throw LedgerError.remote(.notConfigured)
            case .server, .unexpected:
                throw LedgerError.remote(.unavailable)
            }
        }
    }

    /// Starts polling with an immediate refresh (also used on returning to the foreground).
    func startPolling() {
        guard pollTask == nil, syncState != .accessEnded else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        var failures = 0
        var delay = Duration.zero
        while !Task.isCancelled {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
            }
            if inFlight > 0 {
                delay = pollInterval
                continue
            }
            do {
                try await refresh()
                failures = 0
                if base?.hasEnded == true { break }
                delay = pollInterval
            } catch LedgerError.remote(.accessEnded) {
                break
            } catch {
                failures += 1
                delay = min(pollInterval * Int(pow(2.0, Double(min(failures, 5)))), maximumBackoff)
            }
        }
        pollTask = nil
    }

    private func endAccess() {
        syncState = .accessEnded
        stopPolling()
    }

    // MARK: - Snapshots

    /// Accepts an authoritative snapshot (never an older one) and rebuilds what is shown.
    @discardableResult
    private func accept(_ room: RoomDTO) async -> ExpenseID? {
        if let base, room.revision < base.revision { return lastExpenseID }
        let changed = room != base
        base = room
        lastSynced = now()
        if syncState != .accessEnded {
            syncState = optimistic.count > 1 ? .sending(optimistic.count - 1) : .synced(lastSynced ?? now())
        }
        if changed || lastExpenseID == nil && room.isTerminal {
            lastExpenseID = await hooks.didChange(room)
        }
        // Always rebuild: a confirmed or refused change removes its preview even when the room is unchanged.
        await rebuild()
        return lastExpenseID
    }

    private func rebuild() async {
        guard let base else { return }
        let local = await hooks.local()
        let groupID = local.room?.groupID ?? GroupID(roomID.rawValue)
        let room = RemoteRoomMapper.room(base, base: local.room, groupID: groupID, finalExpenseID: local.finalExpenseID)
        var workspace = RemoteRoomMapper.workspace(base, room: room, local: local.snapshot, groupName: local.groupName)
        for (_, command) in optimistic {
            guard let current = workspace.room(roomID) else { break }
            do {
                let result = try LedgerEngine.perform(.receipt(command.rebased(to: current.revision)), on: workspace,
                                                      actor: workspace.currentUserID, now: now())
                workspace = LedgerEngine.apply(result.changes, to: workspace)
            } catch {
                continue // The server decides; the preview simply omits a change it can't show.
            }
        }
        if var shown = workspace.room(roomID) {
            // Views build their next command from this revision, so it is always the server's.
            shown.revision = base.revision
            workspace = workspace.replacingRooms([shown])
        }
        display = workspace
        revision += 1
    }

    // MARK: - Unsupported ledger operations

    func resetToSampleData(referenceDate: Date) async throws { throw LedgerError.unavailable }
    func eraseAll() async throws { throw LedgerError.unavailable }
}

extension LedgerSnapshot {
    nonisolated func replacingRooms(_ rooms: [ReceiptRoom]) -> LedgerSnapshot {
        LedgerSnapshot(currentUserID: currentUserID, members: Array(members.values), groups: groups, expenses: allExpenses,
                       settlements: settlements, paymentDestinations: paymentDestinations, paymentAttempts: paymentAttempts,
                       events: events, defaultCurrency: defaultCurrency, receiptRooms: rooms)
    }
}

extension LedgerError {
    /// A server refusal in the app's own terms where one exists, else the server's safe message.
    nonisolated static func from(_ refusal: ServerRefusal, command: ReceiptRoomCommand?, room: RoomDTO?) -> LedgerError {
        let state = room.flatMap { ReceiptRoomState(rawValue: $0.state) } ?? .open
        let mapped: ReceiptRoomError? = switch refusal.code {
        case "cannot_remove_others": .cannotRemoveOthers
        case "units_unavailable": .unitsUnavailable(available: refusal.available ?? 0)
        case "item_quantity_unknown": .itemQuantityUnknown
        case "unreviewed_shares": .unreviewedShares((refusal.participantIds ?? []).map(RemoteRoomMapper.member))
        case "room_expired": .roomExpired
        case "room_closed": .roomClosed
        case "host_only": .hostOnly
        case "not_allowed_in_state": .notAllowedInState(state)
        case "room_finalized": .notAllowedInState(.finalized)
        case "room_cancelled": .notAllowedInState(.cancelled)
        case "item_not_found": .itemNotFound
        case "item_not_claimable": .itemNotClaimable
        case "charge_not_found": .chargeNotFound
        case "dispute_not_found": .disputeNotFound
        case "item_has_custom_split": .itemHasCustomSplit
        case "no_claim_to_remove": .noClaimToRemove
        case "cannot_include_others": .cannotIncludeOthers
        case "dispute_already_resolved": .disputeAlreadyResolved
        case "note_required": .noteRequired
        case "note_too_long": .noteTooLong
        case "not_ready_to_finalize", "unresolved_dispute": .notReadyToFinalize([])
        case "item_already_claimed":
            if let item = command.flatMap(RemoteRoomLedger.claimedItem),
               let holder = room?.claims.first(where: { $0.itemId == RemoteRoomMapper.id(item) && $0.participantId != room?.viewer.participantId }) {
                .itemAlreadyClaimed(by: RemoteRoomMapper.member(holder.participantId))
            } else {
                nil
            }
        default: nil
        }
        return mapped.map(LedgerError.receipt) ?? .remote(.refused(refusal.message))
    }
}
