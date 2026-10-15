import Foundation
@testable import SquareUp
import Testing

/// Firebase Authentication's REST API, played by a scripted transport: no Firebase users are
/// created and no email is sent.
@Suite("Account session · Firebase REST")
struct AccountSessionAuthTests {
    static let configuration = RemoteConfiguration.make(scheme: "https", host: "squareup.example", authMode: "firebase", firebaseAPIKey: "test-key")!

    static func session(_ transport: ScriptedTransport, keychain: KeychainStore = KeychainStore(service: "test.auth.\(UUID())"),
                        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_792_000_000) }) -> AccountSession {
        AccountSession(configuration: configuration, transport: transport, keychain: keychain, now: now)
    }

    static func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static func tokens(_ uid: String = "uid-maya", email: String? = "maya@example.com") -> Data {
        var body: [String: Any] = ["idToken": "id-token", "refreshToken": "refresh-1", "expiresIn": "3600", "localId": uid]
        if let email { body["email"] = email }
        return json(body)
    }

    static func lookup(verified: Bool, createdAt: String = "1792000000000") -> Data {
        json(["users": [["localId": "uid-maya", "email": "maya@example.com", "emailVerified": verified, "displayName": "Maya Chen", "createdAt": createdAt]]])
    }

    static func firebaseError(_ code: String) -> Data { json(["error": ["code": 400, "message": code]]) }

    static func method(_ request: URLRequest) -> String { request.url?.lastPathComponent ?? "" }

    static func body(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    @Test func withoutAnAccountNothingIsCreatedSilently() async {
        let transport = ScriptedTransport { _, _ in (200, Self.tokens()) }
        let session = Self.session(transport)
        await #expect(throws: AccountSession.Failure.signedOut) { _ = try await session.authorizationHeader() }
        #expect(await transport.requests.isEmpty, "no anonymous account is made to get past sign-in")
        #expect(await session.storedAccount == nil)
    }

    @Test func signUpThenLookupRemembersVerificationForOfflineLaunches() async throws {
        let transport = ScriptedTransport { request, _ in
            switch Self.method(request) {
            case "accounts:signUp": (200, Self.tokens())
            case "accounts:lookup": (200, Self.lookup(verified: false))
            default: (500, Data())
            }
        }
        let session = Self.session(transport)
        try await session.addEmail("maya@example.com", password: "correct-horse-9")
        let signUp = await transport.requests[0]
        #expect(Self.body(signUp)["email"] as? String == "maya@example.com")
        #expect(signUp.url?.query()?.contains("key=test-key") == true)
        let details = try await session.lookup()
        #expect(details == AccountSession.AccountDetails(userID: "uid-maya", email: "maya@example.com", emailVerified: false,
                                                         displayName: "Maya Chen", createdAt: Date(timeIntervalSince1970: 1_792_000_000)))
        let stored = try #require(await session.storedAccount)
        #expect(stored.emailVerified == false && stored.createdAt == Date(timeIntervalSince1970: 1_792_000_000) && !stored.isAnonymous)
    }

    @Test func theVerificationEmailUsesTheAccountsIDToken() async throws {
        let transport = ScriptedTransport { request, _ in
            Self.method(request) == "accounts:signInWithPassword" ? (200, Self.tokens()) : (200, Self.json(["email": "maya@example.com"]))
        }
        let session = Self.session(transport)
        try await session.signIn(email: "maya@example.com", password: "secret")
        try await session.sendEmailVerification()
        let sent = await transport.requests[1]
        #expect(Self.method(sent) == "accounts:sendOobCode")
        #expect(Self.body(sent)["requestType"] as? String == "VERIFY_EMAIL")
        #expect(Self.body(sent)["idToken"] as? String == "id-token")
    }

    @Test func aRefusedRefreshTokenEndsTheSessionAndForgetsIt() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let first = Self.session(ScriptedTransport { _, _ in (200, Self.tokens()) }, keychain: keychain)
        try await first.signIn(email: "maya@example.com", password: "secret")
        // Next launch: the stored refresh token is refused.
        let transport = ScriptedTransport { _, _ in (400, Self.firebaseError("TOKEN_EXPIRED")) }
        let relaunched = Self.session(transport, keychain: keychain)
        #expect(await relaunched.storedAccount != nil)
        await #expect(throws: AccountSession.Failure.sessionEnded) { _ = try await relaunched.restore() }
        #expect(await relaunched.storedAccount == nil)
        #expect(keychain.data(for: "account.firebase") == nil)
    }

    @Test func beingOfflineAtLaunchKeepsTheSession() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let first = Self.session(ScriptedTransport { _, _ in (200, Self.tokens()) }, keychain: keychain)
        try await first.signIn(email: "maya@example.com", password: "secret")
        let relaunched = Self.session(ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }, keychain: keychain)
        await #expect(throws: AccountSession.Failure.offline) { _ = try await relaunched.restore() }
        #expect(await relaunched.storedAccount?.email == "maya@example.com")
    }

    @Test func simultaneousRequestsShareOneTokenRefresh() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let first = Self.session(ScriptedTransport { _, _ in (200, Self.tokens()) }, keychain: keychain)
        try await first.signIn(email: "maya@example.com", password: "secret")
        let refreshed = Self.json(["id_token": "fresh", "refresh_token": "refresh-2", "expires_in": "3600"])
        let transport = ScriptedTransport { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return (200, refreshed)
        }
        let relaunched = Self.session(transport, keychain: keychain)
        async let one = relaunched.authorizationHeader()
        async let two = relaunched.authorizationHeader()
        async let three = relaunched.authorizationHeader()
        let headers = try await [one, two, three]
        #expect(headers == ["Bearer fresh", "Bearer fresh", "Bearer fresh"])
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        ("EMAIL_EXISTS", AccountSession.Failure.emailInUse),
        ("INVALID_EMAIL", .invalidEmail),
        ("WEAK_PASSWORD : Password should be at least 6 characters", .weakPassword),
        ("PASSWORD_DOES_NOT_MEET_REQUIREMENTS : Missing password requirements", .weakPassword),
        ("INVALID_LOGIN_CREDENTIALS", .invalidCredentials),
        ("EMAIL_NOT_FOUND", .invalidCredentials),
        ("INVALID_PASSWORD", .invalidCredentials),
        ("USER_DISABLED", .accountDisabled),
        ("TOO_MANY_ATTEMPTS_TRY_LATER : Try again later", .tooManyAttempts),
        ("OPERATION_NOT_ALLOWED", .operationNotAllowed),
        ("TOKEN_EXPIRED", .sessionEnded),
        ("USER_NOT_FOUND", .sessionEnded),
        ("SOMETHING_NEW", .unavailable),
    ])
    func firebaseErrorsMapToPlainFailures(_ message: String, _ failure: AccountSession.Failure) {
        #expect(AccountSession.failure(for: message) == failure)
        #expect(!LedgerErrorMessages.text(for: failure).isEmpty)
    }

    @Test func wrongEmailAndWrongPasswordReadTheSame() {
        // Privacy: nothing says whether an address has an account.
        #expect(AccountSession.failure(for: "EMAIL_NOT_FOUND") == AccountSession.failure(for: "INVALID_PASSWORD"))
    }

    @Test func passwordResetAnswersTheSameForUnknownAddresses() async throws {
        let transport = ScriptedTransport { _, _ in (400, Self.firebaseError("EMAIL_NOT_FOUND")) }
        try await Self.session(transport).sendPasswordReset(email: "nobody@example.com")
        let sent = await transport.requests[0]
        #expect(Self.body(sent)["requestType"] as? String == "PASSWORD_RESET")
    }

    @Test func anEnforcedPasswordPolicyIsRead() async {
        let enforced = ScriptedTransport { _, _ in
            (200, Self.json(["enforcementState": "ENFORCE", "customStrengthOptions": ["minPasswordLength": 10, "containsNumericCharacter": true]]))
        }
        let policy = await Self.session(enforced).passwordPolicy()
        #expect(policy == AccountSession.PasswordPolicy(minimumLength: 10, requiresNumber: true))
        let off = ScriptedTransport { _, _ in (200, Self.json(["enforcementState": "OFF"])) }
        #expect(await Self.session(off).passwordPolicy() == nil)
        let failing = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await Self.session(failing).passwordPolicy() == nil)
    }

    @Test func anOlderAnonymousAccountIsUpgradedInPlace() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        // An anonymous account written by an earlier build.
        let anonymous = try JSONEncoder().encode(AccountSession.Account(userID: "uid-anon", email: nil, refreshToken: "refresh-anon"))
        keychain.set(anonymous, for: "account.firebase")
        let transport = ScriptedTransport { request, _ in
            switch request.url?.host() {
            case "securetoken.googleapis.com": (200, Self.json(["id_token": "anon-id", "refresh_token": "refresh-anon", "expires_in": "3600"]))
            default: (200, Self.tokens("uid-anon"))
            }
        }
        let session = Self.session(transport, keychain: keychain)
        #expect(await session.storedAccount?.isAnonymous == true)
        try await session.addEmail("maya@example.com", password: "correct-horse-9")
        let update = await transport.requests.last
        #expect(update.map(Self.method) == "accounts:update", "linked, not a new account")
        #expect(await session.storedAccount?.userID == "uid-anon")
    }

    @Test func anAlreadyDeletedAccountCountsAsDeleted() async throws {
        let transport = ScriptedTransport { request, _ in
            Self.method(request) == "accounts:signInWithPassword" ? (200, Self.tokens()) : (400, Self.firebaseError("USER_NOT_FOUND"))
        }
        let session = Self.session(transport)
        try await session.signIn(email: "maya@example.com", password: "secret")
        try await session.deleteAccount() // a previous attempt's response was lost
        #expect(await session.storedAccount == nil)
    }

    @Test func aStaleSignInIsNotTreatedAsAnEndedSession() {
        #expect(AccountSession.failure(for: "CREDENTIAL_TOO_OLD_LOGIN_AGAIN") == .recentSignInRequired)
        #expect(!LedgerErrorMessages.text(for: AccountSession.Failure.recentSignInRequired).isEmpty)
    }

    @Test func theRememberedAccountIsReadableAtLaunch() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        #expect(AccountSession.rememberedUserID(keychain: keychain) == nil)
        try await Self.session(ScriptedTransport { _, _ in (200, Self.tokens()) }, keychain: keychain).signIn(email: "maya@example.com", password: "s")
        #expect(AccountSession.rememberedUserID(keychain: keychain) == "uid-maya")
    }
}
