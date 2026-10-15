import Foundation
@testable import SquareUp
import Testing

/// Every account's local data in its own namespace, on disk (a temporary Application Support).
@MainActor
struct IsolationKit {
    let root: URL
    let layout: AccountStorageLayout
    /// Every scope's housekeeping; the files are removed only after it finishes.
    let maintenance = ScopeMaintenance()

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = AccountStorageLayout(root: root)
    }

    func factory() -> AccountScopeFactory {
        AccountScopeFactory(configuration: LaunchConfiguration(), remote: nil, layout: layout, account: nil,
                            connectivity: ConnectivityMonitor(forcedStatus: .online), haptics: HapticsService(), quickEntry: QuickEntryService(),
                            maintenance: maintenance)
    }

    func session(legacy: LegacyDataRegistry? = nil) -> AppSession {
        AppSession(signedOut: AppEnvironment(ledger: InMemoryLedgerStore(nil), configuration: LaunchConfiguration()), factory: factory(), legacy: legacy)
    }

    /// An earlier build's unscoped store holding the sample groups (Riley's existing data).
    func makeLegacyStore(sample: Bool = true) throws {
        let store = SwiftDataLedgerStore(container: try ModelContainerFactory.make(url: layout.legacyLedgerURL))
        if sample { try store.seedIfEmpty(referenceDate: DemoScenario.fixedReferenceDate) }
    }

    func registry(write: @escaping (Data, URL) throws -> Void = LegacyDataRegistry.atomicWrite) -> LegacyDataRegistry {
        LegacyDataRegistry(layout: layout, write: write)
    }

    /// The open account's group names (a brand-new account, with no person yet, has none).
    func groupNames(_ session: AppSession) async throws -> [String] {
        let store = try #require(session.scope).store
        do {
            return try await store.snapshot().groups.map(\.name).sorted()
        } catch LedgerError.currentUserMissing {
            return []
        }
    }

    /// Every file and directory name under the temporary root.
    func allNames() -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
    }

    /// Removes the files once every scope's housekeeping has stopped (it may still be reading them).
    func cleanUp() {
        let root = root
        let maintenance = maintenance
        Task { @MainActor in
            await maintenance.waitForAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@Suite("Accounts · local data isolation", .serialized)
@MainActor
struct AccountIsolationTests {
    static let riley = "firebase-uid-riley-0001"
    static let maya = "firebase-uid-maya-0002"

    private func start(_ session: AppSession, _ uid: String, name: String) async throws {
        let scope = try session.open(uid: uid)
        try await (scope.store as? any LocalIdentityPreparing)?.prepareCurrentUser(id: MemberID(), displayName: name)
    }

    @Test func accountAThenBThenAKeepSeparateLocalGroups() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        let session = kit.session()
        #expect(session.scope == nil, "nothing is open before an account signs in")

        try await start(session, Self.riley, name: "Riley")
        _ = try await session.scope!.store.createGroup(GroupDraft(name: "Riley's Trip"))
        let rileyStore = session.scope!.store
        session.close()
        #expect(session.scope == nil && session.environment === session.signedOutEnvironment, "signed out: the empty environment")
        await #expect(throws: LedgerError.currentUserMissing) { try await session.environment.ledger.snapshot() }

        try await start(session, Self.maya, name: "Maya")
        #expect(try await kit.groupNames(session) == [], "B starts empty: nothing of A's")
        _ = try await session.scope!.store.createGroup(GroupDraft(name: "Maya's Dinner"))
        #expect(session.scope!.store !== rileyStore)

        try session.open(uid: Self.riley) // switching closes B first
        #expect(try await kit.groupNames(session) == ["Riley's Trip"])
        #expect(try await session.scope!.store.snapshot().currentUser?.displayName == "Riley")
        try session.open(uid: Self.maya)
        #expect(try await kit.groupNames(session) == ["Maya's Dinner"])
    }

    @Test func eachAccountHasItsOwnFilesNamedByAOneWayHash() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        let session = kit.session()
        try await start(session, Self.riley, name: "Riley")
        try await start(session, Self.maya, name: "Maya")
        let riley = AccountNamespace(uid: Self.riley)
        let maya = AccountNamespace(uid: Self.maya)
        #expect(riley != maya && riley == AccountNamespace(uid: Self.riley), "stable per UID")
        #expect(FileManager.default.fileExists(atPath: kit.layout.ledgerURL(for: riley).path()))
        #expect(FileManager.default.fileExists(atPath: kit.layout.ledgerURL(for: maya).path()))
        #expect(kit.layout.receiptsDirectory(for: riley) != kit.layout.receiptsDirectory(for: maya))
        #expect(kit.layout.roomDirectoryURL(for: riley) != kit.layout.roomDirectoryURL(for: maya))
        #expect(AccountStorageLayout.keychainService(for: riley) != AccountStorageLayout.keychainService(for: maya))
        #expect(AccountStorageLayout.defaultsSuiteName(for: riley) != AccountStorageLayout.defaultsSuiteName(for: maya))
        let names = kit.allNames().joined(separator: "/")
        #expect(!names.contains("uid") && !names.contains("riley") && !names.contains("maya"), "no UID or email in any file name")
        #expect(!riley.description.contains(riley.id), "log descriptions show only a short prefix")
    }

    @Test func sharedGroupCachesCursorsAndQueuedChangesStayWithTheirAccount() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        let cache = SharedGroupCache(root: kit.layout.sharedGroupCacheRoot)
        let snapshot = SharedFixtures.snapshot()
        let queued = SharedGroupCache.UnsentChange(
            envelope: GroupCommandEnvelope(type: "addExpense", payload: [:], expectedRevision: 3, knownCursor: snapshot.cursor),
            summary: "Add Groceries · $12.00", queuedAt: .now
        )
        cache.save(SharedGroupCache.GroupEntry(snapshot: snapshot, cachedAt: .now, unsent: [queued]), group: SharedFixtures.groupID, account: Self.riley)
        #expect(cache.group(SharedFixtures.groupID, account: Self.maya) == nil, "another account sees nothing")
        #expect(cache.cachedGroupIDs(account: Self.maya).isEmpty)

        // Riley signs out (the scope closes) and back in: the cursor and the queued change are still there.
        let session = kit.session()
        try await start(session, Self.riley, name: "Riley")
        session.close()
        try await start(session, Self.maya, name: "Maya")
        try session.open(uid: Self.riley)
        let entry = try #require(cache.group(SharedFixtures.groupID, account: Self.riley))
        #expect(entry.snapshot.cursor == snapshot.cursor && entry.unsent.map(\.envelope.idempotencyKey) == [queued.envelope.idempotencyKey])
    }

    @Test func closingStopsAnAccountsServices() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        let session = kit.session()
        try await start(session, Self.riley, name: "Riley")
        let groups = session.scope!.sharedGroups
        session.close()
        #expect(groups.summaries.isEmpty && groups.profile == nil && groups.accountState == .signedOut)
        #expect(session.generation == 2, "opened once, closed once")
    }
}

@Suite("Accounts · data from an earlier build", .serialized)
@MainActor
struct LegacyMigrationTests {
    static let riley = AccountIsolationTests.riley
    static let maya = AccountIsolationTests.maya

    @Test func theAccountThatWasUsingItClaimsItOnceAndKeepsIt() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore()
        let registry = kit.registry()
        registry.inspect(rememberedUID: Self.riley) { (try? LegacyStoreInspector.counts(at: kit.layout.legacyLedgerURL))?.isEmpty == false }
        #expect(registry.claim.state == .pending && registry.claim.candidate == AccountNamespace(uid: Self.riley))

        let session = kit.session(legacy: registry)
        try session.open(uid: Self.riley)
        #expect(session.scope!.usesLegacyData, "Riley's existing data is preserved")
        #expect(try await kit.groupNames(session).isEmpty == false)
        #expect(registry.claim.state == .claimed && registry.claim.owner == AccountNamespace(uid: Self.riley))
        #expect(session.legacyOffer == nil)

        // Maya, on the same iPhone, is never given it.
        try session.open(uid: Self.maya)
        #expect(!session.scope!.usesLegacyData && session.legacyOffer == nil && !session.canReviewLegacyData)
        #expect(try await kit.groupNames(session).isEmpty)
        #expect(throws: LegacyDataRegistry.ClaimError.ownedByAnotherAccount) { try registry.claim(for: AccountNamespace(uid: Self.maya)) }

        // The record is durable: a relaunch reads the same owner, and Riley gets the same data back.
        let relaunched = kit.registry()
        #expect(relaunched.claim.owner == AccountNamespace(uid: Self.riley))
        relaunched.inspect(rememberedUID: Self.maya) { true }
        #expect(relaunched.claim.owner == AccountNamespace(uid: Self.riley), "inspection never rewrites a record")
        let again = kit.session(legacy: relaunched)
        try again.open(uid: Self.riley)
        #expect(again.scope!.usesLegacyData)
        try relaunched.claim(for: AccountNamespace(uid: Self.riley)) // idempotent
    }

    @Test func withNoKnownOwnerItIsOfferedNotAssigned() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore()
        let registry = kit.registry()
        registry.inspect(rememberedUID: nil) { true }
        let session = kit.session(legacy: registry)

        try session.open(uid: Self.maya)
        #expect(!session.scope!.usesLegacyData, "quarantined: not opened for anyone automatically")
        let offer = try #require(session.legacyOffer)
        #expect(offer.canClaim && offer.counts.groups > 0)
        session.declineLegacyData()
        #expect(session.legacyOffer == nil && !session.canReviewLegacyData)
        try session.open(uid: Self.riley)
        try session.open(uid: Self.maya)
        #expect(session.legacyOffer == nil, "Maya said it isn't hers: she isn't asked again")

        try session.open(uid: Self.riley)
        #expect(session.legacyOffer != nil, "the real owner can still choose it")
        try session.claimLegacyData()
        #expect(session.scope!.usesLegacyData && registry.claim.owner == AccountNamespace(uid: Self.riley))
        #expect(try await kit.groupNames(session).isEmpty == false)
    }

    @Test func anAccountWithItsOwnGroupsCannotAbsorbIt() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore()
        let registry = kit.registry()
        registry.inspect(rememberedUID: nil) { true }
        let session = kit.session(legacy: registry)
        let scope = try session.open(uid: Self.maya)
        try await (scope.store as? any LocalIdentityPreparing)?.prepareCurrentUser(id: MemberID(), displayName: "Maya")
        _ = try await scope.store.createGroup(GroupDraft(name: "Maya's Dinner"))
        session.postponeLegacyOffer()
        #expect(!session.canReviewLegacyData, "combining would hide Maya's own groups")
        #expect(throws: LegacyDataRegistry.ClaimError.nothingToClaim) { try session.claimLegacyData() }
        #expect(registry.claim.state == .pending)
    }

    @Test func anInterruptedClaimIsRetriedSafely() throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore()
        kit.registry().inspect(rememberedUID: Self.riley) { true }
        struct DiskFull: Error {}
        var failing = true
        let flaky = kit.registry { data, url in
            if failing { throw DiskFull() }
            try LegacyDataRegistry.atomicWrite(data, to: url)
        }
        #expect(throws: LegacyDataRegistry.ClaimError.writeFailed) { try flaky.claim(for: AccountNamespace(uid: Self.riley)) }
        #expect(flaky.claim.state == .pending && kit.registry().claim.state == .pending, "nothing half-done")

        // Signing in while the record can't be written opens Riley's own (empty) space, not the earlier data.
        let session = kit.session(legacy: flaky)
        try session.open(uid: Self.riley)
        #expect(!session.scope!.usesLegacyData)
        session.close()

        failing = false
        try session.open(uid: Self.riley)
        #expect(session.scope!.usesLegacyData, "the next attempt binds it")
        #expect(kit.registry().claim.owner == AccountNamespace(uid: Self.riley))
    }

    @Test func anAnonymousAccountThatUpgradesKeepsItsData() throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore()
        let anonymous = "firebase-uid-anonymous-host"
        let registry = kit.registry()
        // An earlier build's anonymous account was hosting rooms on this iPhone…
        registry.inspect(rememberedUID: anonymous) { true }
        // …and creating an account upgrades it in place (same UID).
        let session = kit.session(legacy: registry)
        try session.open(uid: anonymous)
        #expect(session.scope!.usesLegacyData && registry.claim.owner == AccountNamespace(uid: anonymous))
    }

    @Test func aStoreHoldingNoGroupsOrExpensesIsNotEarlierData() throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        try kit.makeLegacyStore(sample: false)
        let registry = kit.registry()
        registry.inspect(rememberedUID: Self.riley) { (try? LegacyStoreInspector.counts(at: kit.layout.legacyLedgerURL))?.isEmpty == false }
        #expect(registry.claim.state == .none)
        #expect(registry.resolution(for: AccountNamespace(uid: Self.riley), ownSpaceIsEmpty: true) == .unavailable)
    }

    @Test func newAccountsStartEmpty() async throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        let registry = kit.registry()
        registry.inspect(rememberedUID: nil) { false }
        let session = kit.session(legacy: registry)
        try session.open(uid: "firebase-uid-brand-new")
        #expect(try await kit.groupNames(session).isEmpty)
        #expect(!session.scope!.usesLegacyData && session.legacyOffer == nil)
    }
}

@Suite("Accounts · a fresh install starts clean")
struct FreshInstallTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test.fresh.\(UUID())")! }

    @Test func aFreshInstallClearsWhatAnEarlierInstallLeftInTheKeychain() {
        let defaults = defaults()
        var cleared = 0
        #expect(FreshInstall.clearLeftovers(defaults: defaults, hasLocalData: false) { cleared += 1 })
        #expect(cleared == 1)
        #expect(!FreshInstall.clearLeftovers(defaults: defaults, hasLocalData: false) { cleared += 1 }, "only once")
        #expect(cleared == 1)
    }

    @Test func anExistingInstallIsNeverSignedOutByTheUpdate() {
        let defaults = defaults()
        var cleared = 0
        #expect(!FreshInstall.clearLeftovers(defaults: defaults, hasLocalData: true) { cleared += 1 }, "it has local data: an update")
        #expect(cleared == 0 && defaults.bool(forKey: FreshInstall.markerKey))
    }

    @MainActor
    @Test func localDataIsDetectedFromTheAccountsFolder() throws {
        let kit = IsolationKit()
        defer { kit.cleanUp() }
        #expect(!FreshInstall.hasLocalData(kit.layout))
        try kit.layout.prepareDirectory(for: AccountNamespace(uid: "uid-maya"))
        #expect(FreshInstall.hasLocalData(kit.layout))
    }
}
