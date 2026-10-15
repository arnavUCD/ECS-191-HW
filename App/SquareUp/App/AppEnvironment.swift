import Foundation
import Observation
import OSLog

/// The dependency container injected at the root. Features read only what they need.
///
/// There is exactly one per scene graph; nothing here is a global singleton.
@Observable
final class AppEnvironment {
    @ObservationIgnored let ledger: any LedgerStore
    /// This iPhone's own ledger (local groups), also inside a shared group's environment.
    @ObservationIgnored let rootLedger: any LedgerStore
    @ObservationIgnored let connectivity: ConnectivityMonitor
    @ObservationIgnored let haptics: HapticsService
    @ObservationIgnored let quickEntry: QuickEntryService
    @ObservationIgnored let handoff: PaymentHandoffService
    @ObservationIgnored let receipts: ReceiptServices
    @ObservationIgnored let configuration: LaunchConfiguration
    /// Milestone 4: shared Receipt Rooms (publishing, invitations, joining, account).
    @ObservationIgnored let sharing: SharingService
    /// Set only in the environment for one shared room's screens: its live session. The room
    /// screens are the same as for a local room; this tells them they are shared.
    @ObservationIgnored let remoteRoom: RemoteRoomLedger?
    /// Milestone 7: the account's shared P2P groups (profile, invitations, publishing, sync).
    @ObservationIgnored let sharedGroups: SharedGroupsService
    /// Set only in the environment for one shared group's screens: its server-backed ledger.
    @ObservationIgnored let sharedGroup: SharedGroupLedger?
    /// Milestone 5: the person's AI-processing choice, and the server route when this build has one.
    @ObservationIgnored let receiptAI: ReceiptAISettings
    @ObservationIgnored let receiptIntelligence: (any ReceiptIntelligenceServicing)?
    /// The account backend for the launch flow, or `nil` when this build opens without an account
    /// (no Firebase configured, a local development server, previews, and the historical UI tests).
    @ObservationIgnored var authBackend: (any AuthBackend)?
    /// Demo Mode: this account is a demo workspace of fictional sample data (labelled on Home and in
    /// Profile, with Reset demo data). Set when its scope opens; derived environments carry it.
    @ObservationIgnored var isDemoWorkspace = false
    @ObservationIgnored private let fixedNow: Date?

    init(
        ledger: any LedgerStore,
        connectivity: ConnectivityMonitor = ConnectivityMonitor(),
        haptics: HapticsService = HapticsService(),
        quickEntry: QuickEntryService = QuickEntryService(),
        handoff: PaymentHandoffService? = nil,
        receipts: ReceiptServices? = nil,
        configuration: LaunchConfiguration = LaunchConfiguration(),
        fixedNow: Date? = nil,
        sharing: SharingService? = nil,
        remoteRoom: RemoteRoomLedger? = nil,
        receiptAI: ReceiptAISettings? = nil,
        receiptIntelligence: (any ReceiptIntelligenceServicing)? = nil,
        sharedGroups: SharedGroupsService? = nil,
        sharedGroup: SharedGroupLedger? = nil,
        rootLedger: (any LedgerStore)? = nil
    ) {
        self.ledger = ledger
        self.rootLedger = rootLedger ?? ledger
        self.connectivity = connectivity
        self.haptics = haptics
        self.quickEntry = quickEntry
        self.handoff = handoff ?? PaymentHandoffService(simulatesHandoffs: configuration.simulatesHandoffs)
        self.receipts = receipts ?? .temporary()
        self.configuration = configuration
        self.fixedNow = fixedNow
        self.sharing = sharing ?? SharingService(configuration: nil, local: ledger, directory: SharedRoomDirectory(fileURL: nil))
        self.remoteRoom = remoteRoom
        // Tests, previews, and in-memory launches never read or write the device's real choice.
        let isEphemeral = configuration.usesInMemoryStore || configuration.scenario != nil || configuration.isUITesting
        self.receiptAI = receiptAI ?? ReceiptAISettings(defaults: isEphemeral ? nil : .standard)
        self.receiptIntelligence = receiptIntelligence ?? self.sharing.receiptIntelligence()
        self.sharedGroups = sharedGroups ?? SharedGroupsService(configuration: nil, account: nil, cache: SharedGroupCache(root: nil), local: ledger)
        self.sharedGroup = sharedGroup
    }

    /// The environment for one shared room: same services, but the room's live session as the ledger.
    func shared(_ session: RemoteRoomLedger) -> AppEnvironment {
        carryingAccount(AppEnvironment(ledger: session, connectivity: connectivity, haptics: haptics, quickEntry: quickEntry, handoff: handoff,
                                       receipts: receipts, configuration: configuration, fixedNow: fixedNow, sharing: sharing, remoteRoom: session,
                                       receiptAI: receiptAI, receiptIntelligence: receiptIntelligence, sharedGroups: sharedGroups, sharedGroup: sharedGroup,
                                       rootLedger: rootLedger))
    }

    /// The environment for one shared group's screens: same services, the group's server-backed
    /// ledger as the ledger. Group detail, the composer, settle-up, and payments run unchanged on it.
    func shared(group ledger: SharedGroupLedger) -> AppEnvironment {
        carryingAccount(AppEnvironment(ledger: ledger, connectivity: connectivity, haptics: haptics, quickEntry: quickEntry, handoff: handoff,
                                       receipts: receipts, configuration: configuration, fixedNow: fixedNow, sharing: sharing, remoteRoom: remoteRoom,
                                       receiptAI: receiptAI, receiptIntelligence: receiptIntelligence, sharedGroups: sharedGroups, sharedGroup: ledger,
                                       rootLedger: rootLedger))
    }

    /// The environment for a group: its shared-group environment when it's shared, else this one.
    func environment(for groupID: GroupID?) -> AppEnvironment {
        guard let groupID else { return isInsideSharedGroup ? local : self }
        if sharedGroup?.groupID == groupID { return self }
        if let ledger = sharedGroups.ledger(for: groupID) { return shared(group: ledger) }
        return isInsideSharedGroup ? local : self
    }

    /// This iPhone's own environment (local groups).
    var local: AppEnvironment {
        guard isInsideSharedGroup else { return self }
        return carryingAccount(AppEnvironment(
            ledger: rootLedger, connectivity: connectivity, haptics: haptics, quickEntry: quickEntry, handoff: handoff, receipts: receipts,
            configuration: configuration, fixedNow: fixedNow, sharing: sharing, remoteRoom: nil, receiptAI: receiptAI,
            receiptIntelligence: receiptIntelligence, sharedGroups: sharedGroups, sharedGroup: nil, rootLedger: rootLedger
        ))
    }

    /// A derived environment (a shared group's or room's) keeps the account requirement.
    func carryingAccount(_ derived: AppEnvironment) -> AppEnvironment {
        derived.authBackend = authBackend
        derived.isDemoWorkspace = isDemoWorkspace
        return derived
    }

    /// The base environment (this iPhone's own ledger) when inside a shared group's screens.
    var isInsideSharedGroup: Bool { sharedGroup != nil }

    /// Changes the AI receipt-processing choice (milestone 5 §7.4). Turning AI off also asks the
    /// server to delete this account's cached results; they expire within 24 hours regardless.
    func setReceiptAIMode(_ mode: ReceiptAIMode) async {
        let wasAutomatic = receiptAI.mode == .automatic
        receiptAI.choose(mode)
        if mode == .onDeviceOnly, wasAutomatic { await receiptIntelligence?.deleteCachedResults() }
    }

    /// The current instant. Fixed in previews and UI tests so relative dates are stable.
    var now: Date { fixedNow ?? .now }

    /// Whether this build requires an account (the launch flow). Sample data and the prototype
    /// identity switcher are then hidden: they would replace a real person's ledger.
    var requiresAccount: Bool { authBackend != nil }

    /// Whether long-running decorative animation (the hero aurora) should run.
    var allowsAmbientAnimation: Bool { !configuration.isUITesting }

    static func live(configuration: LaunchConfiguration = .current) -> AppEnvironment {
        if let scenario = configuration.scenario {
            return scenario.environment(configuration: configuration)
        }
        do {
            if configuration.erasesStoreAtLaunch, !configuration.usesInMemoryStore {
                ModelContainerFactory.eraseOnDiskStore()
                try? FileManager.default.removeItem(at: ReceiptAssetStore.defaultDirectory())
            }
            let container = try ModelContainerFactory.make(inMemory: configuration.usesInMemoryStore)
            let fixedNow = configuration.referenceDate
            let store = SwiftDataLedgerStore(container: container, now: { fixedNow ?? .now })
            let remote = remoteConfiguration(for: configuration)
            // Builds without accounts (local demos, a development server, the historical UI tests)
            // keep one device-wide ledger with the sample data. Builds with accounts use
            // `AppSession.live` instead: every account gets its own, and a new one starts empty.
            try store.seedIfEmpty(referenceDate: configuration.referenceDate ?? .now)
            // P2P scope: the seeded sample organization from earlier builds is removed; any other
            // legacy organization data stays on disk and is excluded from the ledger on read.
            try store.removeRetiredSampleData()
            // An in-memory ledger gets throwaway receipt files so UI-test runs never accumulate images.
            let receipts = configuration.usesInMemoryStore ? ReceiptServices.temporary()
                : ReceiptServices(directory: ReceiptAssetStore.defaultDirectory())
            let sharing = SharingService(
                configuration: remote, local: store,
                directory: SharedRoomDirectory(fileURL: configuration.usesInMemoryStore ? nil : SharedRoomDirectory.defaultFileURL())
            )
            // Milestone 7: shared groups use the same server and the same account as shared rooms.
            let sharedGroups = SharedGroupsService(
                configuration: remote, account: sharing.account,
                cache: SharedGroupCache(root: configuration.usesInMemoryStore ? nil : SharedGroupCache.defaultRoot()), local: store
            )
            sharing.sharedLedgerForGroup = { [weak sharedGroups] id in sharedGroups?.ledger(for: id) }
            sharing.sharedLedgerForRoom = { [weak sharedGroups] room in
                guard let sharedGroups, let id = await sharedGroups.groupID(containingRoom: room) else { return nil }
                return sharedGroups.ledger(for: id)
            }
            let environment = AppEnvironment(
                ledger: store, receipts: receipts, configuration: configuration, fixedNow: configuration.referenceDate, sharing: sharing,
                sharedGroups: sharedGroups
            )
            environment.connectivity.start()
            Task { await sharedGroups.start() }
            Task {
                guard let snapshot = try? await store.snapshot() else { return }
                await receipts.removeOrphans(referencedBy: snapshot, now: .now)
            }
            return environment
        } catch {
            Log.persistence.fault("Could not open the ledger store: \(String(describing: type(of: error)), privacy: .public)")
            let unavailable = InMemoryLedgerStore(nil)
            unavailable.failure = .storage(String(describing: type(of: error)))
            return AppEnvironment(ledger: unavailable, configuration: configuration)
        }
    }

    /// The server this build talks to. Shared rooms are off in UI tests (no network) unless a test
    /// server is given; otherwise they use the configured server.
    static func remoteConfiguration(for configuration: LaunchConfiguration) -> RemoteConfiguration? {
        #if DEBUG
        // Demo Mode against a local server: the build's Firebase setup, with a development origin.
        if let url = configuration.demoServer, let bundled = RemoteConfiguration.fromBundle() {
            return RemoteConfiguration(baseURL: url, authMode: .firebase, firebaseAPIKey: bundled.firebaseAPIKey)
        }
        #endif
        return configuration.sharedRoomsServer.flatMap { url in
            RemoteConfiguration.make(scheme: url.scheme, host: url.port.map { "\(url.host() ?? ""):\($0)" } ?? url.host(),
                                     authMode: "development", firebaseAPIKey: nil)
        } ?? (configuration.isUITesting ? nil : RemoteConfiguration.fromBundle())
    }

    /// Reset Sample Data: the ledger and every receipt image this app stored — nothing else.
    func resetSampleData() async throws {
        try await ledger.resetToSampleData(referenceDate: now)
        await receipts.assets.removeAll()
        // A sample group that is now shared stays shared: its local copy is set aside again.
        if let marker = ledger as? any PublishedGroupMarking {
            for id in sharedGroups.sharedGroupIDs { try? await marker.markPublished(id) }
        }
    }

    static func preview(_ scenario: DemoScenario = .standard) -> AppEnvironment {
        scenario.environment(configuration: LaunchConfiguration())
    }
}

extension DemoScenario {
    func environment(configuration: LaunchConfiguration) -> AppEnvironment {
        let referenceDate = configuration.referenceDate ?? DemoScenario.fixedReferenceDate
        let store = InMemoryLedgerStore(snapshot(referenceDate: referenceDate), now: { referenceDate })
        store.failure = failure
        store.latency = latency
        return AppEnvironment(
            ledger: store,
            connectivity: ConnectivityMonitor(forcedStatus: connectivity ?? .online),
            configuration: configuration,
            fixedNow: referenceDate
        )
    }
}
