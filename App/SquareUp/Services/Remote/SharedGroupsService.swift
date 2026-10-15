import Foundation
import Observation
import OSLog

/// Real multi-user P2P groups (milestone 7): the account, its server-backed profile, the shared
/// groups it belongs to, publishing a local group, invitations, and joining.
///
/// - Shared groups need a recoverable account (§2.5). A device-only (anonymous) account can still
///   host and join single Live Receipt Rooms; it is asked to add an email first.
/// - Every shared group has one `SharedGroupLedger`; screens for that group run on it.
/// - Signing out stops every group, purges this account's cached groups from the iPhone, and
///   forgets the profile, before another account can sign in (§13.1).
/// - Publishing validates the whole local group first (`publicationReview`), uploads it with one
///   stable publication ID reused on every retry, and hides the local copy only after the
///   server's answer is stored. A failure leaves the local group exactly as it was.
@Observable
final class SharedGroupsService {
    nonisolated enum AccountState: Equatable, Sendable {
        /// This build has no server configured: everything stays on this iPhone.
        case notConfigured
        case signedOut
        /// An anonymous account: works on this iPhone only.
        case deviceOnly
        /// A recoverable account without a profile yet ("Choose the name people will see").
        case needsProfile(email: String?)
        case ready(email: String?)
        /// The sign-in expired or was revoked; sign in again (cached groups stay readable meanwhile).
        case sessionEnded
    }

    nonisolated enum ListState: Equatable, Sendable {
        case idle
        case loading
        case synced(Date)
        case offline(lastSynced: Date?)
    }

    private(set) var accountState: AccountState = .notConfigured
    private(set) var profile: ProfileDTO?
    private(set) var summaries: [GroupSummaryDTO] = []
    private(set) var listState: ListState = .idle
    /// Increments whenever any shared group's confirmed state changes (Home and Activity re-derive).
    private(set) var version = 0
    /// An invitation opened from a link or pasted, waiting to be shown (`JoinGroupView`).
    var pendingInvitation: PendingGroupInvitation?
    /// Invitations someone in a shared group sent to this account ("Find a person"), waiting for an
    /// answer at the top of Groups. Refreshed with the group list; changed only by
    /// `SharedGroupsService+DirectInvitations`.
    var receivedInvitations: [ReceivedInvitationDTO] = []

    nonisolated struct PendingGroupInvitation: Identifiable, Equatable, Sendable {
        let id = UUID()
        let code: String
    }

    @ObservationIgnored let configuration: RemoteConfiguration?
    @ObservationIgnored let account: AccountSession?
    @ObservationIgnored let api: SharedGroupAPI?
    @ObservationIgnored let cache: SharedGroupCache
    @ObservationIgnored private let local: any LedgerStore
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var ledgers: [GroupID: SharedGroupLedger] = [:]
    @ObservationIgnored private(set) var accountID: String?
    /// The links of invitations this account created, so the owner can show an unused one again.
    /// The server keeps only a digest; the code lives here, in the Keychain, keyed by account.
    @ObservationIgnored let invitationLinks: KeychainStore

    init(configuration: RemoteConfiguration?, account: AccountSession?, transport: any HTTPTransport = URLSessionTransport(),
         cache: SharedGroupCache, local: any LedgerStore, now: @escaping () -> Date = { .now },
         invitationLinks: KeychainStore = KeychainStore(service: "\(Log.subsystem).groupInvitations")) {
        self.configuration = configuration
        self.account = account
        self.invitationLinks = invitationLinks
        self.cache = cache
        self.local = local
        self.now = now
        if let configuration, let account {
            api = SharedGroupAPI(configuration: configuration, transport: transport, account: account)
        } else {
            api = nil
        }
    }

    var isConfigured: Bool { api != nil }
    var isReady: Bool { if case .ready = accountState { true } else { false } }
    /// The current account's seat ID is per group; this is the profile's default member ID.
    var profileMemberID: MemberID? { profile.flatMap { MemberID(string: $0.memberId) } }

    // MARK: - Account

    /// Reads the account state and, for a recoverable account, its profile and cached groups.
    func start() async {
        await refreshAccount()
        if isReady { await refreshGroups() }
    }

    func refreshAccount() async {
        guard let account, let api else {
            accountState = .notConfigured
            return
        }
        let status = await account.status
        let recoverable = await account.isRecoverable
        accountID = await account.userID
        switch status {
        case .signedOut where !account.isDevelopment:
            accountState = .signedOut
            return
        case .deviceOnly where !recoverable:
            accountState = .deviceOnly
            return
        default:
            break
        }
        guard let accountID else {
            accountState = .signedOut
            return
        }
        let email = status.identity.map(Self.shown)
        // Offline first: the cached profile and groups show immediately.
        if let cached = cache.account(accountID) {
            profile = cached.profile ?? profile
            if summaries.isEmpty { summaries = cached.groups }
        }
        do {
            let dto = try await api.account()
            profile = dto.profile
            accountState = dto.profile == nil ? .needsProfile(email: email) : .ready(email: email)
            saveAccountCache()
        } catch {
            switch error {
            case .offline, .timedOut:
                accountState = profile == nil ? .needsProfile(email: email) : .ready(email: email)
            case .account(.sessionEnded):
                accountState = .sessionEnded
            case .server(let refusal) where refusal.code == "unauthenticated":
                accountState = .sessionEnded
            default:
                accountState = profile == nil ? .needsProfile(email: email) : .ready(email: email)
            }
        }
    }

    /// Adds an email and password to this iPhone's account (keeping its user ID, so rooms it
    /// hosts stay its own), or creates a new account if there is none.
    func createAccount(email: String, password: String) async throws(LedgerError) {
        try await accountCall { try await $0.addEmail(email, password: password) }
        await refreshAccount()
    }

    /// Signs in to an existing account (e.g. on a new iPhone). Shared groups come back from the server.
    func signIn(email: String, password: String) async throws(LedgerError) {
        let previous = accountID
        try await accountCall { try await $0.signIn(email: email, password: password) }
        let current = await account?.userID
        if let previous, previous != current {
            // A different account: nothing of the previous one may remain visible.
            forgetEverything(purging: previous)
        }
        await start()
    }

    func sendPasswordReset(email: String) async throws(LedgerError) {
        try await accountCall { try await $0.sendPasswordReset(email: email) }
    }

    /// Signs out: stops every shared group, removes this account's cached groups from the iPhone,
    /// and forgets the profile. Shared groups stay on the server; local groups are untouched.
    func signOut() async {
        if let accountID { forgetEverything(purging: accountID) }
        await account?.signOut()
        accountID = nil
        await refreshAccount()
    }

    private func forgetEverything(purging accountID: String) {
        ledgers.values.forEach { $0.stopPolling() }
        ledgers.removeAll()
        summaries = []
        receivedInvitations = []
        profile = nil
        cache.purge(account: accountID)
        listState = .idle
        version += 1
    }

    private func accountCall(_ body: (AccountSession) async throws -> Void) async throws(LedgerError) {
        guard let account else { throw .remote(.notConfigured) }
        do {
            try await body(account)
        } catch let failure as AccountSession.Failure {
            throw .remote(.signInFailed(failure))
        } catch {
            throw .remote(.unavailable)
        }
    }

    // MARK: - Profile

    /// Creates or updates the name people see in shared groups.
    func saveProfile(displayName: String) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .rule(.memberNameRequired) }
        do {
            profile = try await api.saveProfile(ProfileRequest(
                displayName: name, locale: Locale.current.identifier, currency: Locale.current.currency?.identifier,
                memberId: profile?.memberId ?? SharedGroupMapper.id(MemberID())
            ))
        } catch {
            throw LedgerError.from(error)
        }
        await refreshAccount()
        saveAccountCache()
    }

    /// Saves one of this person's payment methods to their profile (shared groups read it from there).
    func saveDestination(_ destination: PaymentDestination) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            profile = try await api.saveDestination(SharedGroupMapper.id(destination.id), SharedGroupMapper.destinationRequest(destination))
        } catch {
            throw LedgerError.from(error)
        }
        saveAccountCache()
        version += 1
    }

    func deleteDestination(_ id: PaymentDestinationID) async throws(LedgerError) {
        guard let api else { throw .remote(.notConfigured) }
        do {
            profile = try await api.deleteDestination(SharedGroupMapper.id(id))
        } catch {
            throw LedgerError.from(error)
        }
        saveAccountCache()
        version += 1
    }

    /// This person's payment methods as the app's model (owner = the profile's member ID).
    var profileDestinations: [PaymentDestination] {
        guard let owner = profileMemberID else { return [] }
        return (profile?.destinations ?? []).compactMap { SharedGroupMapper.destination($0, owner: owner) }
    }

    private func saveAccountCache() {
        guard let accountID else { return }
        var entry = cache.account(accountID) ?? SharedGroupCache.AccountEntry()
        entry.profile = profile
        entry.groups = summaries
        entry.updatedAt = now()
        cache.save(entry, account: accountID)
    }

    // MARK: - Groups

    func refreshGroups() async {
        guard let api, isReady else { return }
        listState = .loading
        do {
            summaries = try await api.groups()
            listState = .synced(now())
            saveAccountCache()
            version += 1
            await refreshReceivedInvitations()
        } catch {
            if case .offline = error { listState = .offline(lastSynced: nil) } else if case .timedOut = error { listState = .offline(lastSynced: nil) } else {
                listState = .idle
            }
            if summaries.isEmpty, let accountID {
                // Offline: groups cached on this iPhone are still readable.
                summaries = cache.cachedGroupIDs(account: accountID).compactMap { id in
                    guard let entry = cache.group(id, account: accountID) else { return nil }
                    return GroupSummaryDTO(group: entry.snapshot.group, viewer: entry.snapshot.viewer, cursor: entry.snapshot.cursor,
                                           memberCount: entry.snapshot.members.filter { $0.status != "removed" }.count,
                                           confirmedNet: entry.snapshot.balances.confirmedNets[entry.snapshot.viewer.memberId] ?? 0,
                                           awaitingYourConfirmation: 0)
                }
                version += 1
            }
        }
    }

    var sharedGroupIDs: [GroupID] { summaries.compactMap { GroupID(string: $0.group.id) } }

    func isShared(_ id: GroupID) -> Bool { summaries.contains { $0.group.id == SharedGroupMapper.id(id) } || ledgers[id] != nil }

    /// The live ledger for a shared group this account belongs to (created on first use).
    func ledger(for id: GroupID) -> SharedGroupLedger? {
        if let existing = ledgers[id] { return existing }
        guard let api, let accountID, isShared(id) else { return nil }
        let ledger = SharedGroupLedger(groupID: id, account: accountID, api: api, cache: cache, profile: { [weak self] in self?.profile })
        ledger.didChange = { [weak self] in self?.version += 1 }
        ledgers[id] = ledger
        return ledger
    }

    /// Starts (or updates) the ledger of a group this account just created, published, or joined.
    func register(_ snapshot: GroupSnapshotDTO) -> SharedGroupLedger? {
        guard let api, let accountID, let id = GroupID(string: snapshot.group.id) else { return nil }
        let ledger = ledgers[id] ?? SharedGroupLedger(groupID: id, account: accountID, api: api, cache: cache, profile: { [weak self] in self?.profile },
                                                      initial: snapshot)
        ledger.didChange = { [weak self] in self?.version += 1 }
        ledgers[id] = ledger
        if !summaries.contains(where: { $0.group.id == snapshot.group.id }) {
            summaries.append(GroupSummaryDTO(group: snapshot.group, viewer: snapshot.viewer, cursor: snapshot.cursor,
                                             memberCount: snapshot.members.filter { $0.status != "removed" }.count,
                                             confirmedNet: snapshot.balances.confirmedNets[snapshot.viewer.memberId] ?? 0, awaitingYourConfirmation: 0))
            summaries.sort { $0.group.name.localizedStandardCompare($1.group.name) == .orderedAscending }
        }
        saveAccountCache()
        version += 1
        return ledger
    }

    /// The group whose ledger contains this expense, attempt, or receipt room (navigation).
    func groupID(containing expense: ExpenseID) -> GroupID? {
        ledgers.first { $0.value.base?.expenses.contains { $0.id == SharedGroupMapper.id(expense) } == true }?.key
    }

    func groupID(containingAttempt attempt: PaymentAttemptID) -> GroupID? {
        ledgers.first { $0.value.base?.attempts.contains { $0.id == SharedGroupMapper.id(attempt) } == true }?.key
    }

    /// The shared group holding a receipt draft or room started on this iPhone (synchronous lookup).
    func groupID(holdingRoom room: ReceiptRoomID) -> GroupID? {
        ledgers.first { $0.value.holdsRoom(room) }?.key
    }

    func groupID(containingRoom room: ReceiptRoomID) async -> GroupID? {
        for (id, ledger) in ledgers where await (try? ledger.snapshot().room(room)) != nil { return id }
        return nil
    }

    /// The workspaces of every shared group this iPhone has opened or cached (Home, Activity).
    func workspaces() async -> [LedgerSnapshot] {
        for id in sharedGroupIDs where ledgers[id] == nil { _ = ledger(for: id) }
        var result: [LedgerSnapshot] = []
        for ledger in ledgers.values {
            // A group listed by the server but never opened here is fetched once.
            if ledger.base == nil { try? await ledger.refresh() }
            if ledger.base != nil, let snapshot = try? await ledger.snapshot() { result.append(snapshot) }
        }
        return result
    }

    // MARK: - Keeping Home and Activity current

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Seconds between background refreshes while the app is active and no group screen is polling.
    @ObservationIgnored var slowSyncInterval: Duration = .seconds(20)
    @ObservationIgnored var waitingSyncInterval: Duration = .seconds(5)

    /// Refreshes every shared group once (pull to refresh on Home, Groups, and Activity).
    func refreshAll() async {
        await refreshGroups()
        for id in sharedGroupIDs where ledgers[id] == nil { _ = ledger(for: id) }
        for ledger in ledgers.values where !ledger.isPolling && ledger.syncState != .accessEnded {
            try? await ledger.refresh()
        }
    }

    /// While the app is active: a slow refresh of every shared group (quicker while a payment
    /// involving this person is waiting), so Home shows a reported payment without opening the
    /// group. Stops in the background (§7.3); the transport stays replaceable by push later.
    func startSync() {
        guard syncTask == nil, isConfigured else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isReady { await refreshAll() }
                let waiting = ledgers.values.contains { $0.currentPollInterval == $0.fastPollInterval }
                try? await Task.sleep(for: waiting ? waitingSyncInterval : slowSyncInterval)
            }
        }
    }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: - Creating

    /// Creates a new shared group directly on the server (signed in and online, §8.4).
    func createGroup(_ draft: GroupDraft) async throws(LedgerError) -> GroupID {
        guard let api else { throw .remote(.notConfigured) }
        guard isReady else { throw .remote(.signInFailed(.notConfigured)) }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .rule(.groupNameRequired) }
        let id = GroupID()
        let details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: GroupCreateResponse
        do {
            response = try await api.createGroup(CreateGroupRequest(groupId: SharedGroupMapper.id(id), name: name, details: details.isEmpty ? nil : details,
                                                                    symbol: draft.symbolName, currency: draft.currency.rawValue, simplifiesDebts: true))
        } catch {
            throw LedgerError.from(error)
        }
        _ = register(response.snapshot)
        Log.sync.info("Created a shared group")
        return id
    }

    // MARK: - Publishing a local group (§8)

    nonisolated struct PublicationReview: Equatable, Sendable {
        /// Problems that must be fixed first; nothing is uploaded while any remain.
        var blockers: [String]
        /// What will and won't be shared, shown before the person confirms.
        var disclosures: [String]
        var memberCount: Int
        var expenseCount: Int

        var canPublish: Bool { blockers.isEmpty }
    }

    /// Checks a local group against every publication rule without changing anything.
    func publicationReview(of groupID: GroupID) async -> PublicationReview {
        guard let snapshot = try? await local.snapshot() else {
            return PublicationReview(blockers: [String(localized: "This group couldn't be read.")], disclosures: [], memberCount: 0, expenseCount: 0)
        }
        return Self.review(groupID, in: snapshot)
    }

    /// Publishes a local group exactly once. Returns the shared group's ID (the same as the local one).
    func publish(_ groupID: GroupID) async throws(LedgerError) -> GroupID {
        guard let api, let accountID else { throw .remote(.notConfigured) }
        guard isReady else { throw .remote(.signInFailed(.notConfigured)) }
        let snapshot: LedgerSnapshot
        do {
            snapshot = try await local.snapshot()
        } catch {
            throw error as? LedgerError ?? .unavailable
        }
        let review = Self.review(groupID, in: snapshot)
        guard review.canPublish else { throw .remote(.refused(review.blockers.joined(separator: "\n"))) }
        // One stable publication ID per local group, reused on every retry (§8.3).
        var entry = cache.account(accountID) ?? SharedGroupCache.AccountEntry()
        let publicationID = entry.publications[SharedGroupMapper.id(groupID)] ?? SharedGroupMapper.id(MemberID())
        entry.publications[SharedGroupMapper.id(groupID)] = publicationID
        cache.save(entry, account: accountID)
        let request = Self.publication(groupID, in: snapshot, publicationID: publicationID)
        let response: GroupCreateResponse
        do {
            response = try await api.publish(request)
        } catch {
            if case .server(let refusal) = error, refusal.code == "entity_exists" {
                throw .remote(.refused(String(localized: "This group was already shared, possibly from another iPhone. Ask whoever shared it for an invitation.")))
            }
            throw LedgerError.from(error)
        }
        // Stored first; only then is the local copy set aside.
        _ = register(response.snapshot)
        if let marker = local as? any PublishedGroupMarking {
            try? await marker.markPublished(groupID)
        }
        Log.sync.info("Published a local group (\(response.created ? "new" : "already published", privacy: .public))")
        return groupID
    }

    // MARK: - Invitations

    /// A new single-use invitation. Each call makes a distinct one; its link is kept for showing again.
    func createInvitation(for groupID: GroupID, seat: MemberID?) async throws(LedgerError) -> GroupInvitationDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            let invitation = try await api.createInvitation(group: SharedGroupMapper.id(groupID), seat: seat.map(SharedGroupMapper.id))
            if let code = invitation.code, let url = invitation.url {
                saveLink(InvitationLink(code: code, url: url, appUrl: invitation.appUrl), for: invitation.invitationId)
            }
            try? await ledgers[groupID]?.refresh()
            return invitation
        } catch {
            throw LedgerError.from(error)
        }
    }

    func preview(_ code: String) async throws(LedgerError) -> GroupInvitationPreviewDTO {
        guard let api else { throw .remote(.notConfigured) }
        do {
            return try await api.preview(code: code)
        } catch {
            throw LedgerError.from(groupInvitation: error)
        }
    }

    /// Accepts an invitation with this account (needs a live answer; never queued). Returns the group.
    func accept(_ code: String, displayName: String) async throws(LedgerError) -> GroupID {
        guard let api else { throw .remote(.notConfigured) }
        let response: AcceptGroupInvitationResponse
        do {
            response = try await api.accept(code: code, displayName: displayName)
        } catch {
            throw LedgerError.from(groupInvitation: error)
        }
        guard let id = GroupID(string: response.snapshot.group.id) else { throw .remote(.unavailable) }
        _ = register(response.snapshot)
        Log.sync.info("Joined a shared group")
        return id
    }
}

extension LedgerError {
    /// An invitation request's failure in terms the join screen can explain (§4.3 step 8).
    nonisolated static func from(groupInvitation error: RemoteError) -> LedgerError {
        if case .server(let refusal) = error {
            switch refusal.code {
            case "invitation_expired": return .remote(.invitation(.expired))
            case "invitation_revoked": return .remote(.invitation(.revoked))
            case "invitation_used": return .remote(.invitation(.used))
            case "invitation_invalid": return .remote(.invitation(.invalid))
            case "already_member": return .remote(.invitation(.alreadyMember))
            case "group_archived": return .remote(.invitation(.archived))
            case "seat_unavailable": return .remote(.invitation(.seatUnavailable))
            case "account_required": return .remote(.invitation(.accountRequired))
            case "profile_required": return .remote(.invitation(.profileRequired))
            case "group_full": return .remote(.invitation(.groupFull))
            default: break
            }
        }
        return from(error)
    }
}

// MARK: - Launch flow (sign-in and setup)

extension SharedGroupsService {
    /// An email as is; a phone number written for people.
    private static func shown(_ identity: String) -> String {
        identity.hasPrefix("+") ? PhoneNumbers.shared.display(identity) : identity
    }

    /// Reads the account from the server (launch flow): the profile, or `nil` when none was chosen
    /// yet. Unlike `refreshAccount`, failures are returned so the caller can tell offline from
    /// signed out.
    func loadAccount() async throws(RemoteError) -> ProfileDTO? {
        guard let account, let api else { throw .notConfigured }
        accountID = await account.userID
        let email = await account.status.identity.map(Self.shown)
        let dto = try await api.account()
        profile = dto.profile
        accountState = dto.profile == nil ? .needsProfile(email: email) : .ready(email: email)
        saveAccountCache()
        return dto.profile
    }

    /// After an account was created or signed in: a different account than before leaves nothing
    /// of the previous one visible.
    func accountDidChange(from previous: String?) async {
        let current = await account?.userID
        if let previous, previous != current { forgetEverything(purging: previous) }
        if let cached = accountID, cached != current, cached != previous { forgetEverything(purging: cached) }
        accountID = current
    }

    /// Closes this account's shared groups on this iPhone (signing out or switching accounts): stops
    /// syncing and polling and drops every open group. Its cache — snapshots, cursors, and changes
    /// still waiting to be sent — stays in this account's own namespace for when it signs in again.
    func close() {
        stopSync()
        ledgers.values.forEach { $0.stopPolling() }
        ledgers.removeAll()
        summaries = []
        receivedInvitations = []
        profile = nil
        listState = .idle
        accountState = .signedOut
        accountID = nil
        version += 1
    }

    /// Changes in shared groups that haven't reached the server yet (kept for this account).
    var unsentChangeCount: Int { ledgers.values.reduce(0) { $0 + $1.unsent.count } }
}
