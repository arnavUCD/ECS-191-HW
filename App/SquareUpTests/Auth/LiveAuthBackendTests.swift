import Foundation
@testable import SquareUp
import Testing

/// `LiveAuthBackend` over Firebase's REST API and Square Up's account endpoint, both scripted, with
/// each account's local data opened in its own scope.
@Suite("Account backend · Firebase, the account endpoint, and account scopes", .serialized)
@MainActor
struct LiveAuthBackendTests {
    typealias Session = AccountSessionAuthTests

    struct Kit {
        let transport: ScriptedTransport
        let backend: LiveAuthBackend
        let session: AppSession
        let account: AccountSession
        let isolation: IsolationKit
    }

    static func kit(_ handler: @escaping ScriptedTransport.Handler) -> Kit {
        let transport = ScriptedTransport(handler)
        let configuration = Session.configuration
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.auth.\(UUID())"))
        let isolation = IsolationKit()
        let factory = AccountScopeFactory(
            configuration: LaunchConfiguration(), remote: configuration, layout: isolation.layout, account: account,
            connectivity: ConnectivityMonitor(forcedStatus: .online), haptics: HapticsService(), quickEntry: QuickEntryService(),
            transport: transport, maintenance: isolation.maintenance
        )
        let session = AppSession(signedOut: AppEnvironment(ledger: InMemoryLedgerStore(nil), configuration: LaunchConfiguration()),
                                 factory: factory, legacy: nil)
        return Kit(transport: transport, backend: LiveAuthBackend(account: account, session: session), session: session, account: account,
                   isolation: isolation)
    }

    nonisolated static func account(profile name: String?) -> Data {
        var account: [String: Any] = ["recoverable": true]
        if let name {
            account["profile"] = ["memberId": "7d1f0000-0000-4000-8000-0000000000a1", "displayName": name, "locale": "en_US", "currency": "USD",
                                  "destinations": [], "createdAt": "2026-10-07T23:00:00Z", "updatedAt": "2026-10-07T23:00:00Z"]
        } else {
            account["profile"] = NSNull()
        }
        return Session.json(["account": account])
    }

    /// Firebase answers for `uid`; the server answers with `server`.
    nonisolated static func firebase(uid: @escaping @Sendable () -> String = { "uid-maya" }, verified: @escaping @Sendable () -> Bool = { false },
                                     server: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> ScriptedTransport.Handler {
        { request, _ in
            switch request.url?.host() {
            case "identitytoolkit.googleapis.com":
                switch Session.method(request) {
                case "accounts:lookup":
                    return (200, Session.json(["users": [["localId": uid(), "email": "\(uid())@example.com", "emailVerified": verified(),
                                                          "createdAt": "1792000000000"]]]))
                case "accounts:update", "accounts:delete": return (200, Session.json(["localId": uid()]))
                case "accounts:sendOobCode": return (200, Session.json(["email": "x@example.com"]))
                default: return (200, Session.tokens(uid()))
                }
            case "securetoken.googleapis.com":
                return (200, Session.json(["id_token": "fresh-token", "refresh_token": "refresh-1", "expires_in": "3600"]))
            default:
                return try server(request)
            }
        }
    }

    @Test func signUpOpensTheNewAccountsOwnEmptySpace() async throws {
        let kit = Self.kit(Self.firebase { _ in (500, Data()) })
        defer { kit.isolation.cleanUp() }
        let details = try await kit.backend.signUp(email: "maya@example.com", password: "correct-horse-9", displayName: "Maya Chen")
        #expect(!details.emailVerified)
        let methods = await kit.transport.requests.map(Session.method)
        #expect(methods == ["accounts:signUp", "accounts:update", "accounts:lookup"])
        #expect(kit.session.namespace == AccountNamespace(uid: "uid-maya"))
        #expect(try await kit.isolation.groupNames(kit.session).isEmpty, "no sample data for a real account")
    }

    @Test func signingOutAndInAsSomeoneElseNeverShowsTheFirstAccountsData() async throws {
        final class Current: @unchecked Sendable { var uid = "uid-riley" }
        let current = Current()
        let kit = Self.kit(Self.firebase(uid: { current.uid }, verified: { true }) { _ in (200, Self.account(profile: "Someone")) })
        defer { kit.isolation.cleanUp() }
        _ = try await kit.backend.signIn(email: "riley@example.com", password: "secret")
        await kit.backend.prepareApp(for: AuthFixtures.profile)
        _ = try await kit.session.scope!.store.createGroup(GroupDraft(name: "Riley's Trip"))
        await kit.backend.signOut()
        #expect(kit.session.scope == nil && kit.session.environment === kit.session.signedOutEnvironment)
        #expect(await kit.backend.storedAccount() == nil)

        current.uid = "uid-maya"
        _ = try await kit.backend.signIn(email: "maya@example.com", password: "secret")
        #expect(try await kit.isolation.groupNames(kit.session).isEmpty)
        await kit.backend.signOut()
        current.uid = "uid-riley"
        _ = try await kit.backend.signIn(email: "riley@example.com", password: "secret")
        #expect(try await kit.isolation.groupNames(kit.session) == ["Riley's Trip"], "back to Riley: Riley's own data")
    }

    @Test func aDeletedAccountIsForgottenOnlyWhenFirebaseSaysItIsGone() async throws {
        final class Mode: @unchecked Sendable { var value = "ok" }
        let mode = Mode()
        let live = Self.firebase(uid: { "uid-riley" }, verified: { true }) { _ in (200, Self.account(profile: "Riley")) }
        let kit = Self.kit { request, attempt in
            switch mode.value {
            case "offline": throw URLError(.notConnectedToInternet)
            case "deleted": return (400, Session.firebaseError("USER_NOT_FOUND"))
            default: return try await live(request, attempt)
            }
        }
        defer { kit.isolation.cleanUp() }
        _ = try await kit.backend.signIn(email: "riley@example.com", password: "secret")
        await kit.backend.prepareApp(for: AuthFixtures.profile)
        _ = try await kit.session.scope!.store.createGroup(GroupDraft(name: "Riley's Trip"))

        mode.value = "offline"
        await #expect(throws: AuthFailure.self) { _ = try await kit.backend.reload() }
        #expect(await kit.backend.storedAccount() != nil, "a network failure never clears the sign-in")

        mode.value = "deleted"
        let failure = await #expect(throws: AuthFailure.self) { _ = try await kit.backend.reload() }
        #expect(failure?.isSessionEnded == true, "Firebase says the account is gone")
        await kit.backend.signOut() // what the launch flow does for an ended session
        #expect(await kit.backend.storedAccount() == nil && kit.session.scope == nil, "credentials cleared; its data unloaded")
        #expect(kit.session.environment === kit.session.signedOutEnvironment, "the next screen shows nothing of it")
    }

    @Test func theProfileIsReadFromTheServerAndKeptForOfflineLaunches() async throws {
        let named = Self.kit(Self.firebase { _ in (200, Self.account(profile: "Maya Chen")) })
        defer { named.isolation.cleanUp() }
        _ = try await named.backend.signIn(email: "maya@example.com", password: "secret")
        #expect(try await named.backend.loadProfile() == AuthFixtures.profile)
        #expect(await named.backend.cachedProfile() == AuthFixtures.profile)
        await named.backend.signOut()
        #expect(await named.backend.cachedProfile() == nil, "signed out: nothing is opened")
    }

    @Test func offlineAndSignedOutAreDifferentProfileFailures() async throws {
        let offline = Self.kit(Self.firebase { _ in throw URLError(.notConnectedToInternet) })
        defer { offline.isolation.cleanUp() }
        _ = try await offline.backend.signIn(email: "maya@example.com", password: "secret")
        await #expect(throws: AuthFailure.account(.offline)) { _ = try await offline.backend.loadProfile() }

        let refused = Self.kit(Self.firebase { _ in
            (401, Session.json(["error": ["code": "unauthenticated", "message": "Sign in", "requestId": "r"]]))
        })
        defer { refused.isolation.cleanUp() }
        _ = try await refused.backend.signIn(email: "maya@example.com", password: "secret")
        let failure = await #expect(throws: AuthFailure.self) { _ = try await refused.backend.loadProfile() }
        #expect(failure?.isSessionEnded == true)
    }

    @Test func aVerifiedAddressGetsAFreshIDTokenImmediately() async throws {
        let kit = Self.kit(Self.firebase(verified: { true }) { _ in (500, Data()) })
        defer { kit.isolation.cleanUp() }
        _ = try await kit.backend.signIn(email: "maya@example.com", password: "secret")
        let before = await kit.transport.requests.count
        let details = try await kit.backend.reload()
        #expect(details.emailVerified)
        let after = await kit.transport.requests.dropFirst(before).compactMap { $0.url?.host() }
        #expect(after == ["identitytoolkit.googleapis.com", "securetoken.googleapis.com"], "lookup, then a forced token refresh")
        #expect(try await kit.account.authorizationHeader() == "Bearer fresh-token")
    }

    @Test func anEmailChangeIsVerifiedBeforeItApplies() async throws {
        let kit = Self.kit(Self.firebase { _ in (500, Data()) })
        defer { kit.isolation.cleanUp() }
        _ = try await kit.backend.signUp(email: "maya@example.com", password: "correct-horse-9", displayName: "Maya")
        let before = await kit.backend.storedAccount()?.email
        try await kit.backend.requestEmailChange(to: "maya.chen@example.com")
        let sent = try #require(await kit.transport.requests.last)
        #expect(Session.method(sent) == "accounts:sendOobCode")
        #expect(Session.body(sent)["requestType"] as? String == "VERIFY_AND_CHANGE_EMAIL")
        #expect(Session.body(sent)["newEmail"] as? String == "maya.chen@example.com")
        #expect(await kit.backend.storedAccount()?.email == before, "unchanged until the link is opened")
    }

    @Test func deletingAnIncompleteSignUpForgetsItAndClosesItsSpace() async throws {
        let kit = Self.kit(Self.firebase { _ in (500, Data()) })
        defer { kit.isolation.cleanUp() }
        _ = try await kit.backend.signUp(email: "maya@example.com", password: "correct-horse-9", displayName: "Maya")
        try await kit.backend.deleteIncompleteAccount()
        #expect(await kit.transport.requests.contains { Session.method($0) == "accounts:delete" })
        #expect(await kit.backend.storedAccount() == nil && kit.session.scope == nil)
    }
}

@Suite("Local ledger · preparing a signed-in person")
@MainActor
struct LocalIdentityTests {
    @Test func anEmptyOnDiskLedgerGetsOnePerson() async throws {
        let store = try SwiftDataLedgerStore(container: ModelContainerFactory.make(inMemory: true))
        let id = MemberID()
        try await store.prepareCurrentUser(id: id, displayName: "Maya Chen")
        let snapshot = try await store.snapshot()
        #expect(snapshot.currentUserID == id && snapshot.members.count == 1 && snapshot.groups.isEmpty)
        try await store.prepareCurrentUser(id: id, displayName: "Maya C.")
        #expect(try await store.snapshot().currentUser?.displayName == "Maya C.", "renamed with the profile")
    }

    @Test func anExistingCurrentUserIsNeverReplaced() async throws {
        let store = try SwiftDataLedgerStore(container: ModelContainerFactory.make(inMemory: true))
        try store.seedIfEmpty(referenceDate: DemoScenario.fixedReferenceDate)
        let before = try await store.snapshot()
        try await store.prepareCurrentUser(id: MemberID(), displayName: "Someone Else")
        let after = try await store.snapshot()
        #expect(after.currentUserID == before.currentUserID && after.currentUser?.displayName == before.currentUser?.displayName)
    }
}
