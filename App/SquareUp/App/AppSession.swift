import Foundation
import Observation
import OSLog
import SwiftData

/// A ledger that can say whether it holds anything a person made (groups or expenses).
protocol LocalDataInspecting {
    func holdsGroupsOrExpenses() -> Bool
}

/// One signed-in account's local world: its own ledger store, receipt images, receipt-room
/// directory and secrets, preferences, shared-group service, and the environment the app's screens
/// run on. Nothing in it is reachable from another account's scope.
@MainActor
final class AccountScope {
    /// `nil` for builds without accounts (one device-wide scope, as before).
    let namespace: AccountNamespace?
    let environment: AppEnvironment
    /// Whether this scope uses the data an earlier build kept without an account (claimed by it).
    let usesLegacyData: Bool
    /// Housekeeping started when the scope opened (removing receipt files nothing references).
    var maintenance: Task<Void, Never>?

    init(namespace: AccountNamespace?, environment: AppEnvironment, usesLegacyData: Bool) {
        self.namespace = namespace
        self.environment = environment
        self.usesLegacyData = usesLegacyData
    }

    var store: any LedgerStore { environment.rootLedger }
    var sharedGroups: SharedGroupsService { environment.sharedGroups }
    var sharing: SharingService { environment.sharing }

    /// Stops everything this account had running (sync, polling, room sessions). Its data stays in
    /// its namespace; releasing the scope releases the SwiftData container.
    func close() {
        maintenance?.cancel()
        sharedGroups.close()
        sharing.close()
    }
}

/// Background housekeeping started by account scopes, kept so it can be awaited.
@MainActor
final class ScopeMaintenance {
    private var tasks: [Task<Void, Never>] = []

    func start(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { await work() }
        tasks.append(task)
        return task
    }

    /// Waits for everything started so far (finished or cancelled).
    func waitForAll() async {
        let pending = tasks
        tasks.removeAll()
        for task in pending { await task.value }
    }
}

/// Builds account scopes. Device-wide services (connectivity, haptics, quick entry, the signed-in
/// Firebase session) are shared; everything holding personal data is per account.
@MainActor
struct AccountScopeFactory {
    let configuration: LaunchConfiguration
    let remote: RemoteConfiguration?
    let layout: AccountStorageLayout
    let account: AccountSession?
    let connectivity: ConnectivityMonitor
    let haptics: HapticsService
    let quickEntry: QuickEntryService
    var transport: any HTTPTransport = URLSessionTransport()
    /// Every scope's housekeeping, so it can be awaited (tests remove their files only afterwards).
    var maintenance = ScopeMaintenance()

    /// Opens the scope for `namespace`. `legacy` opens the earlier build's data (already claimed).
    /// `demo`: a demo workspace (fictional sample data, labelled throughout).
    func make(_ namespace: AccountNamespace, legacy: Bool, demo: Bool = false) throws -> AccountScope {
        let inMemory = configuration.usesInMemoryStore
        let fixedNow = configuration.referenceDate
        let container: ModelContainer
        if inMemory {
            container = try ModelContainerFactory.make(inMemory: true)
        } else if legacy {
            container = try ModelContainerFactory.make(url: layout.legacyLedgerURL)
        } else {
            try layout.prepareDirectory(for: namespace)
            container = try ModelContainerFactory.make(url: layout.ledgerURL(for: namespace))
        }
        let store = SwiftDataLedgerStore(container: container, now: { fixedNow ?? .now })
        if legacy { try store.removeRetiredSampleData() }
        let receipts: ReceiptServices = if inMemory {
            .temporary()
        } else {
            ReceiptServices(directory: legacy ? layout.legacyReceiptsDirectory : layout.receiptsDirectory(for: namespace))
        }
        let roomFile: URL? = inMemory ? nil : (legacy ? layout.legacyRoomDirectoryURL : layout.roomDirectoryURL(for: namespace))
        // Room invitation links are secrets: the legacy owner keeps the Keychain items it already had.
        let roomKeychain = legacy ? KeychainStore() : KeychainStore(service: AccountStorageLayout.keychainService(for: namespace))
        let sharing = SharingService(configuration: remote, local: store, directory: SharedRoomDirectory(fileURL: roomFile),
                                     transport: transport, keychain: roomKeychain, account: account)
        let sharedGroups = SharedGroupsService(configuration: remote, account: account, transport: transport,
                                               cache: SharedGroupCache(root: inMemory ? nil : layout.sharedGroupCacheRoot), local: store)
        Self.connect(sharing, sharedGroups)
        // The AI-processing consent is personal; the legacy owner keeps the choice it made before.
        let ephemeral = inMemory || configuration.isUITesting
        let defaults: UserDefaults? = ephemeral ? nil : (legacy ? .standard : UserDefaults(suiteName: AccountStorageLayout.defaultsSuiteName(for: namespace)))
        let environment = AppEnvironment(
            ledger: store, connectivity: connectivity, haptics: haptics, quickEntry: quickEntry, receipts: receipts, configuration: configuration,
            fixedNow: fixedNow, sharing: sharing, receiptAI: ReceiptAISettings(defaults: defaults), sharedGroups: sharedGroups
        )
        environment.isDemoWorkspace = demo
        let scope = AccountScope(namespace: namespace, environment: environment, usesLegacyData: legacy)
        // Stops if the scope closes first: a closed account's files are never touched.
        scope.maintenance = maintenance.start {
            guard !Task.isCancelled, let snapshot = try? await store.snapshot(), !Task.isCancelled else { return }
            await receipts.removeOrphans(referencedBy: snapshot, now: .now)
        }
        Log.app.info("Opened an account's local data (\(legacy ? "earlier build" : "own", privacy: .public))")
        return scope
    }

    static func connect(_ sharing: SharingService, _ sharedGroups: SharedGroupsService) {
        sharing.sharedLedgerForGroup = { [weak sharedGroups] id in sharedGroups?.ledger(for: id) }
        sharing.sharedLedgerForRoom = { [weak sharedGroups] room in
            guard let sharedGroups, let id = await sharedGroups.groupID(containingRoom: room) else { return nil }
            return sharedGroups.ledger(for: id)
        }
    }

    /// Demo Mode: deletes one account's data from this iPhone — its ledger, receipt images, room
    /// directory, preferences, Keychain items, and cached shared groups. Its scope must be closed.
    func discard(_ namespace: AccountNamespace, uid: String) {
        if !configuration.usesInMemoryStore {
            try? FileManager.default.removeItem(at: layout.directory(for: namespace))
            SharedGroupCache(root: layout.sharedGroupCacheRoot).purge(account: uid)
            UserDefaults.standard.removePersistentDomain(forName: AccountStorageLayout.defaultsSuiteName(for: namespace))
        }
        KeychainStore(service: AccountStorageLayout.keychainService(for: namespace)).removeAll()
    }

    /// Whether a scope's own ledger has anything a person made (used before binding earlier data).
    func isEmpty(_ namespace: AccountNamespace) -> Bool {
        let url = layout.ledgerURL(for: namespace)
        guard !configuration.usesInMemoryStore, FileManager.default.fileExists(atPath: url.path()) else { return true }
        return (try? LegacyStoreInspector.counts(at: url))?.isEmpty ?? true
    }
}

/// Counts what a store holds without exposing any of it (for the "earlier data" choice).
@MainActor
enum LegacyStoreInspector {
    nonisolated struct Counts: Equatable, Sendable {
        var groups: Int
        var expenses: Int
        var people: Int
        /// No groups and no expenses (a store holding only its own person is still "empty").
        var isEmpty: Bool { groups == 0 && expenses == 0 }
    }

    static func counts(at url: URL) throws -> Counts {
        guard FileManager.default.fileExists(atPath: url.path()) else { return Counts(groups: 0, expenses: 0, people: 0) }
        let context = ModelContext(try ModelContainerFactory.make(url: url))
        return Counts(groups: try context.fetchCount(FetchDescriptor<GroupRecord>()),
                      expenses: try context.fetchCount(FetchDescriptor<ExpenseRecord>()),
                      people: try context.fetchCount(FetchDescriptor<MemberRecord>()))
    }
}

/// The app's account session: which account's scope is open, and the environment screens use.
///
/// - Builds that require an account start with **no** scope: the signed-out screens run on an empty
///   environment that holds no personal data. A scope opens only after Firebase confirms the UID,
///   and opening another account's scope first closes and releases the current one.
/// - Builds without accounts have one fixed device scope (the historical behavior).
@MainActor
@Observable
final class AppSession {
    /// An offer to bind data from an earlier build to the signed-in account.
    nonisolated struct LegacyOffer: Identifiable, Equatable, Sendable {
        var id: String { namespace.id }
        let namespace: AccountNamespace
        let counts: LegacyStoreInspector.Counts
        /// The account already has its own data, so the two can't be combined.
        let canClaim: Bool
    }

    nonisolated enum ScopeError: Error, Equatable {
        case storageUnavailable
    }

    private(set) var scope: AccountScope?
    private(set) var legacyOffer: LegacyOffer?
    /// Changes whenever a different account's scope opens or closes (views keyed on it rebuild).
    private(set) var generation = 0

    @ObservationIgnored let signedOutEnvironment: AppEnvironment
    @ObservationIgnored let legacy: LegacyDataRegistry?
    @ObservationIgnored private let factory: AccountScopeFactory?
    /// In-memory builds (UI tests): closed scopes are kept so switching back finds the same data.
    @ObservationIgnored private var keptInMemory: [AccountNamespace: AccountScope] = [:]

    /// The environment the app's screens use right now.
    var environment: AppEnvironment { scope?.environment ?? signedOutEnvironment }

    /// A session for a build that requires accounts.
    init(signedOut: AppEnvironment, factory: AccountScopeFactory, legacy: LegacyDataRegistry?) {
        signedOutEnvironment = signedOut
        self.factory = factory
        self.legacy = legacy
    }

    /// A build without accounts: one fixed scope.
    init(fixed environment: AppEnvironment) {
        signedOutEnvironment = environment
        factory = nil
        legacy = nil
        scope = AccountScope(namespace: nil, environment: environment, usesLegacyData: true)
    }

    var namespace: AccountNamespace? { scope?.namespace }

    /// Opens `uid`'s scope (closing any other first). Earlier data is bound automatically only to
    /// the account remembered as its user; anyone else gets an offer instead.
    @discardableResult
    func open(uid: String, isDemo: Bool = false) throws(ScopeError) -> AccountScope {
        guard let factory else {
            guard let scope else { throw .storageUnavailable }
            return scope
        }
        let namespace = AccountNamespace(uid: uid)
        if let scope, scope.namespace == namespace { return scope }
        close()
        if let kept = keptInMemory[namespace] {
            install(kept)
            return kept
        }
        var useLegacy = false
        legacyOffer = nil
        // A demo workspace never takes, or is offered, data from an earlier build.
        if let legacy, !isDemo {
            switch legacy.resolution(for: namespace, ownSpaceIsEmpty: factory.isEmpty(namespace)) {
            case .owned:
                useLegacy = true
            case .claimAutomatically:
                useLegacy = (try? legacy.claim(for: namespace)) != nil
            case .offer:
                legacyOffer = offer(for: namespace)
            case .unavailable:
                break
            }
        }
        do {
            let opened = try factory.make(namespace, legacy: useLegacy, demo: isDemo)
            install(opened)
            return opened
        } catch {
            Log.persistence.fault("Couldn't open an account's local data: \(String(describing: type(of: error)), privacy: .public)")
            throw .storageUnavailable
        }
    }

    /// Closes the open scope (sign-out, session end, switching). Its data stays in its namespace.
    func close() {
        guard factory != nil, let current = scope else { return }
        current.close()
        if let namespace = current.namespace, factory?.configuration.usesInMemoryStore == true { keptInMemory[namespace] = current }
        scope = nil
        legacyOffer = nil
        generation += 1
    }

    /// Demo Mode: removes a demo workspace's data from this iPhone (closing it first if it's open),
    /// on Reset demo data and Leave demo. Real accounts' data is never discarded here.
    func discardLocalData(uid: String) {
        let namespace = AccountNamespace(uid: uid)
        if scope?.namespace == namespace { close() }
        keptInMemory[namespace] = nil
        factory?.discard(namespace, uid: uid)
    }

    /// "Use with this account": binds the earlier data to the open account and reopens on it.
    func claimLegacyData() throws(LegacyDataRegistry.ClaimError) {
        guard let legacy, let offer = legacyOffer, offer.canClaim, let namespace = scope?.namespace, namespace == offer.namespace,
              let factory else { throw .nothingToClaim }
        try legacy.claim(for: namespace)
        scope?.close()
        scope = nil
        legacyOffer = nil
        guard let reopened = try? factory.make(namespace, legacy: true) else { throw .writeFailed }
        install(reopened)
    }

    /// "Not mine": the earlier data stays aside and this account isn't asked again.
    func declineLegacyData() {
        guard let namespace = scope?.namespace else { return }
        legacy?.decline(for: namespace)
        legacyOffer = nil
    }

    /// "Decide later": hides the prompt for now (Profile still offers it).
    func postponeLegacyOffer() {
        legacyOffer = nil
    }

    /// Whether earlier data could still be offered to the open account (Profile row).
    var canReviewLegacyData: Bool {
        guard let legacy, let scope, let namespace = scope.namespace, !scope.usesLegacyData, !scope.environment.isDemoWorkspace else { return false }
        return legacy.resolution(for: namespace, ownSpaceIsEmpty: !Self.holdsData(scope)) == .offer
    }

    private static func holdsData(_ scope: AccountScope) -> Bool {
        (scope.store as? any LocalDataInspecting)?.holdsGroupsOrExpenses() ?? true
    }

    func reviewLegacyData() {
        guard let namespace = scope?.namespace, canReviewLegacyData else { return }
        legacyOffer = offer(for: namespace)
    }

    private func offer(for namespace: AccountNamespace) -> LegacyOffer? {
        guard let legacy, let counts = try? LegacyStoreInspector.counts(at: legacy.layout.legacyLedgerURL), !counts.isEmpty else { return nil }
        let ownIsEmpty = scope.map { !Self.holdsData($0) } ?? factory?.isEmpty(namespace) ?? false
        return LegacyOffer(namespace: namespace, counts: counts, canClaim: ownIsEmpty)
    }

    private func install(_ opened: AccountScope) {
        opened.environment.authBackend = signedOutEnvironment.authBackend
        scope = opened
        generation += 1
    }
}

extension AppSession {
    /// The session for this launch.
    static func live(configuration: LaunchConfiguration = .current) -> AppSession {
        if let scenario = configuration.scenario {
            return AppSession(fixed: scenario.environment(configuration: configuration))
        }
        let remote = AppEnvironment.remoteConfiguration(for: configuration)
        if remote == nil, !configuration.isUITesting {
            // Config/Remote.xcconfig ships the production client configuration, so a normal build
            // always has it; never pass off a broken configuration as an offline build quietly.
            Log.app.fault("No Square Up server is configured: check Config/Remote.xcconfig (and any Remote.local.xcconfig override). Running on this iPhone only.")
        }
        // Accounts are required with Firebase configured, or for the DEBUG account stand-in.
        guard remote?.authMode == .firebase || configuration.authDemo != nil else {
            return AppSession(fixed: AppEnvironment.live(configuration: configuration))
        }
        let layout = AccountStorageLayout.standard
        if remote?.authMode == .firebase,
           FreshInstall.clearLeftovers(defaults: .standard, hasLocalData: FreshInstall.hasLocalData(layout), clearKeychain: { KeychainStore.removeAllItems() }) {
            Log.app.info("Fresh install: cleared sign-ins an earlier install left in the Keychain")
        }
        let account = remote.flatMap { $0.authMode == .firebase ? AccountSession(configuration: $0, transport: URLSessionTransport()) : nil }
        let connectivity = ConnectivityMonitor()
        connectivity.start()
        let haptics = HapticsService()
        let quickEntry = QuickEntryService()
        let factory = AccountScopeFactory(configuration: configuration, remote: remote, layout: layout, account: account,
                                          connectivity: connectivity, haptics: haptics, quickEntry: quickEntry)
        // Signed out, the screens run on an environment that holds no personal data at all.
        let empty = InMemoryLedgerStore(nil)
        let signedOut = AppEnvironment(
            ledger: empty, connectivity: connectivity, haptics: haptics, quickEntry: quickEntry, receipts: .temporary(), configuration: configuration,
            fixedNow: configuration.referenceDate,
            sharing: SharingService(configuration: remote, local: empty, directory: SharedRoomDirectory(fileURL: nil), account: account),
            receiptAI: ReceiptAISettings(defaults: nil),
            sharedGroups: SharedGroupsService(configuration: remote, account: account, cache: SharedGroupCache(root: nil), local: empty)
        )
        var legacy: LegacyDataRegistry?
        if !configuration.usesInMemoryStore {
            let registry = LegacyDataRegistry(layout: layout)
            registry.inspect(rememberedUID: AccountSession.rememberedUserID()) {
                (try? LegacyStoreInspector.counts(at: layout.legacyLedgerURL))?.isEmpty == false
            }
            legacy = registry
        }
        let session = AppSession(signedOut: signedOut, factory: factory, legacy: legacy)
        signedOut.authBackend = authBackend(configuration: configuration, remote: remote, account: account, session: session)
        return session
    }

    private static func authBackend(configuration: LaunchConfiguration, remote: RemoteConfiguration?, account: AccountSession?,
                                    session: AppSession) -> (any AuthBackend)? {
        #if DEBUG
        if let scenario = configuration.authDemo { return DemoAuthBackend(argument: scenario, session: session) }
        #endif
        guard let account else { return nil }
        let demo = remote.map { DemoWorkspaceAPI(configuration: $0, transport: URLSessionTransport(), account: account) }
        return LiveAuthBackend(account: account, session: session, phone: FirebasePhoneVerifier.shared, demo: demo)
    }
}
