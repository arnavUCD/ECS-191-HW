import Foundation
import OSLog

/// The full-app account (milestone 4 §8.1), backed by Firebase Authentication through its REST
/// API — no SDK dependency. See `DEPENDENCIES.md` and the auth decision in `ARCHITECTURE.md`.
///
/// - Accounts are email and password, or a phone number verified by Firebase's iOS SDK and then
///   adopted here (`adopt`), created or signed in through the launch flow (`AuthCoordinator`).
///   Both kinds share this one session. No account is created silently: without one, requests fail with
///   `signedOut`. An anonymous account left by an earlier build is upgraded in place when its
///   owner creates an account (same user ID, so rooms it hosts stay theirs).
/// - The refresh token lives in the Keychain (this device only); ID tokens are kept in memory and
///   refreshed five minutes before expiry, one refresh at a time.
/// - The last confirmed verification state, creation date, and whether a profile exists are kept
///   with the refresh token so an offline relaunch can still route correctly.
/// - Passwords, tokens, and email addresses are never logged; only Firebase's error code is.
/// - `development` mode (DEBUG builds, local server only) sends `Dev <install id>` instead.
/// - Demo Mode ("Enter Demo") keeps a server-issued demo credential instead of a Firebase account:
///   one isolated workspace of fictional data for this iPhone, sent as `Demo <token>`. Signing in
///   for real (or signing out) forgets it.
actor AccountSession {
    nonisolated struct Account: Codable, Equatable, Sendable {
        let userID: String
        var email: String?
        var refreshToken: String
        /// Last value confirmed by Firebase (`accounts:lookup`); `nil` until first checked.
        var emailVerified: Bool?
        var createdAt: Date?
        /// Whether the server profile was confirmed to exist (offline launches use it).
        var hasProfile: Bool?
        /// The account's verified phone number (E.164), when it has one. Keychain only, never logged.
        var phoneNumber: String?
    }

    /// What Firebase reports about the signed-in account (`accounts:lookup`).
    nonisolated struct AccountDetails: Equatable, Sendable {
        let userID: String
        let email: String?
        let emailVerified: Bool
        let displayName: String?
        let createdAt: Date?
        /// A phone number Firebase verified with a code (E.164); verifies the account like an email.
        var phoneNumber: String?
        /// A demo workspace's account (fictional sample data, no Firebase account).
        var isDemo = false
    }

    /// A demo workspace's credential, issued by the server (`POST /v1/demo/sessions`). Keychain only.
    nonisolated struct DemoCredential: Codable, Equatable, Sendable {
        let userID: String
        let token: String
        let createdAt: Date
        let expiresAt: Date?
    }

    /// The account kept on this iPhone, read without any network request.
    nonisolated struct StoredAccount: Equatable, Sendable {
        let userID: String
        let email: String?
        let emailVerified: Bool?
        let createdAt: Date?
        let hasProfile: Bool?
        var phoneNumber: String?
        var isDemo = false
        /// An older anonymous account (no email, no phone): kept only so creating an account upgrades it.
        var isAnonymous: Bool { !isDemo && email == nil && phoneNumber == nil }
    }

    /// The project's password rules (`v2/passwordPolicy`), when Firebase enforces any.
    nonisolated struct PasswordPolicy: Equatable, Sendable {
        var minimumLength: Int
        var maximumLength: Int?
        var requiresLowercase = false
        var requiresUppercase = false
        var requiresNumber = false
        var requiresSymbol = false
    }

    nonisolated enum Status: Equatable, Sendable {
        case signedOut
        /// Anonymous: works on this iPhone only until an email is added.
        case deviceOnly
        case signedIn(email: String)
        /// A phone account (E.164).
        case signedInWithPhone(String)
        /// A demo workspace (fictional sample data).
        case demo

        /// What identifies the account to its owner: the email, or the phone number.
        var identity: String? {
            switch self {
            case .signedIn(let email): email
            case .signedInWithPhone(let phone): phone
            case .signedOut, .deviceOnly, .demo: nil
            }
        }
    }

    nonisolated enum Failure: Error, Equatable, Sendable {
        case notConfigured
        case offline
        case invalidCredentials
        case emailInUse
        case invalidEmail
        case weakPassword
        case tooManyAttempts
        /// Signed out elsewhere or the refresh token was revoked; sign in again.
        case sessionEnded
        /// No account on this iPhone (nothing is created silently).
        case signedOut
        /// The account was turned off in Firebase.
        case accountDisabled
        /// Email/password sign-in isn't enabled for this Firebase project.
        case operationNotAllowed
        /// A sensitive change (email, deletion) needs a fresh sign-in first.
        case recentSignInRequired
        case unavailable
        // Phone numbers (Firebase phone authentication)
        case invalidPhoneNumber
        /// The six digits don't match the latest code.
        case invalidCode
        /// The code (or the verification it belongs to) expired: send a new one.
        case codeExpired
        /// Square Up's own wait between codes hasn't passed.
        case codeCooldown
        /// Firebase's SMS quota for the project is used up for now.
        case smsQuotaExceeded
        /// The number already belongs to another account (adding it is refused; nothing is merged).
        case phoneInUse
        /// The person closed the reCAPTCHA check.
        case verificationCancelled
        /// Firebase couldn't confirm the request came from Square Up (APNs or reCAPTCHA).
        case appVerificationFailed
        /// Phone sign-in or the number's region isn't enabled for this project.
        case phoneNotAllowed
    }

    private let configuration: RemoteConfiguration
    private let transport: any HTTPTransport
    private let keychain: KeychainStore
    private let now: @Sendable () -> Date
    private var account: Account?
    private var demo: DemoCredential?
    private var idToken: (value: String, expiresAt: Date)?
    private var refreshing: Task<String, any Error>?

    private nonisolated static let accountKey = "account.firebase"
    private nonisolated static let demoKey = "account.demo"
    private static let installKey = "account.development-install-id"

    init(configuration: RemoteConfiguration, transport: any HTTPTransport, keychain: KeychainStore = KeychainStore(),
         now: @escaping @Sendable () -> Date = { .now }) {
        self.configuration = configuration
        self.transport = transport
        self.keychain = keychain
        self.now = now
        account = keychain.data(for: Self.accountKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        demo = keychain.data(for: Self.demoKey).flatMap { try? JSONDecoder().decode(DemoCredential.self, from: $0) }
    }

    /// The user ID remembered in this iPhone's Keychain, read synchronously at launch (before the
    /// session actor exists) to decide who was using data from an earlier build. Never logged.
    nonisolated static func rememberedUserID(keychain: KeychainStore = KeychainStore()) -> String? {
        keychain.data(for: accountKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }?.userID
    }

    /// The account kept on this iPhone, without a network request.
    var storedAccount: StoredAccount? {
        guard configuration.authMode == .firebase else { return nil }
        if let demo {
            return StoredAccount(userID: demo.userID, email: nil, emailVerified: nil, createdAt: demo.createdAt, hasProfile: true, isDemo: true)
        }
        guard let account else { return nil }
        return StoredAccount(userID: account.userID, email: account.email, emailVerified: account.emailVerified,
                             createdAt: account.createdAt, hasProfile: account.hasProfile, phoneNumber: account.phoneNumber)
    }

    var status: Status {
        if configuration.authMode == .development { return .deviceOnly }
        if demo != nil { return .demo }
        guard let account else { return .signedOut }
        if let email = account.email { return .signedIn(email: email) }
        return account.phoneNumber.map(Status.signedInWithPhone) ?? .deviceOnly
    }

    /// A stable identifier for this person on the server (never shown in the UI).
    var userID: String? {
        configuration.authMode == .development ? developmentUserID : (demo?.userID ?? account?.userID)
    }

    /// Whether this iPhone is in a demo workspace.
    var isDemo: Bool { demo != nil }

    /// Whether this account can hold shared groups (milestone 7 §2.5): an email/password or phone
    /// account that can be recovered on another iPhone, or a development account against a local
    /// server. An anonymous account works on this iPhone only.
    var isRecoverable: Bool {
        configuration.authMode == .development || demo != nil || account?.email != nil || account?.phoneNumber != nil
    }

    /// Whether the build talks to a local development server (no real accounts).
    nonisolated var isDevelopment: Bool { configuration.authMode == .development }

    /// `Authorization` value for the API. Throws `signedOut` when there is no account.
    func authorizationHeader(forceRefresh: Bool = false) async throws -> String {
        if configuration.authMode == .development { return "Dev \(developmentUserID)" }
        if let demo { return "Demo \(demo.token)" }
        return await "Bearer \(try validIDToken(forceRefresh: forceRefresh))"
    }

    // MARK: - Email (account recovery)

    /// Adds an email and password to the current anonymous account, keeping the same user ID —
    /// so rooms this person hosts stay theirs. Creates a new account if none exists yet.
    func addEmail(_ email: String, password: String) async throws {
        try requireFirebase()
        if account == nil {
            let response: FirebaseTokenResponse = try await identityToolkit("accounts:signUp", [
                "email": .string(email), "password": .string(password), "returnSecureToken": true,
            ])
            store(response, email: email)
            return
        }
        let token = try await validIDToken(forceRefresh: false)
        let response: FirebaseTokenResponse = try await identityToolkit("accounts:update", [
            "idToken": .string(token), "email": .string(email), "password": .string(password), "returnSecureToken": true,
        ])
        store(response, email: email)
    }

    /// Signs in to an existing email account (e.g. on a new iPhone). Replaces any anonymous
    /// account on this device; rooms hosted by that anonymous account stay with it.
    func signIn(email: String, password: String) async throws {
        try requireFirebase()
        let response: FirebaseTokenResponse = try await identityToolkit("accounts:signInWithPassword", [
            "email": .string(email), "password": .string(password), "returnSecureToken": true,
        ])
        store(response, email: email)
    }

    /// Asks Firebase to email a password-reset link. Square Up never sees or handles the reset
    /// token. The outcome is the same whether or not the address has an account, so the app
    /// can't be used to discover who has one.
    func sendPasswordReset(email: String) async throws {
        try requireFirebase()
        do {
            let _: OobCodeResponse = try await identityToolkit("accounts:sendOobCode", [
                "requestType": "PASSWORD_RESET", "email": .string(email),
            ])
        } catch Failure.invalidCredentials {
            return // EMAIL_NOT_FOUND: answered exactly like success
        }
    }

    /// Sends Firebase's verification email to the signed-in account's address.
    func sendEmailVerification() async throws {
        let token = try await validIDToken(forceRefresh: false)
        let _: OobCodeResponse = try await identityToolkit("accounts:sendOobCode", [
            "requestType": "VERIFY_EMAIL", "idToken": .string(token),
        ])
    }

    /// Asks Firebase for the account's current state — the only trusted source for
    /// `emailVerified`. Remembers the answer for offline launches.
    func lookup() async throws -> AccountDetails {
        if let demo { return Self.details(demo) }
        let token = try await validIDToken(forceRefresh: false)
        let response: LookupResponse = try await identityToolkit("accounts:lookup", ["idToken": .string(token)])
        guard let user = response.users?.first else { throw Failure.sessionEnded }
        let details = AccountDetails(
            userID: user.localId, email: user.email, emailVerified: user.emailVerified ?? false, displayName: user.displayName,
            createdAt: user.createdAt.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }, phoneNumber: user.phoneNumber
        )
        if var account, account.userID == details.userID {
            account.email = details.email ?? account.email
            account.emailVerified = details.emailVerified
            account.createdAt = details.createdAt
            account.phoneNumber = details.phoneNumber
            persist(account)
        }
        return details
    }

    // MARK: - Phone

    /// Adopts a phone sign-in Firebase's SDK completed (`FirebasePhoneVerifier`): its refresh token
    /// is kept exactly like an email sign-in's, so both kinds of account share this one session —
    /// token refresh, sign-out, and relaunch included. Replaces any older anonymous account on this
    /// iPhone, as signing in with an email does.
    func adopt(_ phone: PhoneCredentialSession) throws {
        try requireFirebase()
        let previous = account?.userID == phone.userID ? account : nil
        persist(Account(userID: phone.userID, email: previous?.email, refreshToken: phone.refreshToken, emailVerified: previous?.emailVerified,
                        createdAt: previous?.createdAt, hasProfile: previous?.hasProfile, phoneNumber: phone.phoneNumber))
        idToken = (phone.idToken, now().addingTimeInterval(phone.expiresIn))
    }

    /// Adds a verified phone number to the signed-in account — the same Firebase user, exactly as
    /// the SDK's `link(with:)` does (Identity Toolkit with the user's ID token and `LINK`). A number
    /// that belongs to another account comes back as a temporary proof instead of tokens: refused as
    /// `phoneInUse`, and the accounts are never merged.
    func linkPhone(verificationID: String, code: String) async throws -> AccountDetails {
        let token = try await validIDToken(forceRefresh: false)
        let response: PhoneLinkResponse
        do {
            response = try await identityToolkit("accounts:signInWithPhoneNumber", [
                "idToken": .string(token), "sessionInfo": .string(verificationID), "code": .string(code), "operation": "LINK",
            ])
        } catch Failure.operationNotAllowed {
            throw Failure.phoneNotAllowed
        }
        guard let idToken = response.idToken, let refreshToken = response.refreshToken, let userID = response.localId else {
            throw Failure.phoneInUse
        }
        guard userID == account?.userID else { throw Failure.unavailable } // never switches to another account
        updateTokens(id: idToken, refresh: refreshToken, expiresIn: response.expiresIn.flatMap(TimeInterval.init) ?? 3600)
        if var account, let number = response.phoneNumber {
            account.phoneNumber = number
            persist(account)
        }
        return try await lookup()
    }

    /// Restores the session at launch: exchanges the stored refresh token for a fresh ID token,
    /// then reads the account. `sessionEnded` means the stored credentials no longer work.
    func restore() async throws -> AccountDetails {
        // A demo has no Firebase account; the server confirms its credential when the profile loads.
        if let demo { return Self.details(demo) }
        guard account != nil else { throw Failure.signedOut }
        _ = try await validIDToken(forceRefresh: true)
        return try await lookup()
    }

    /// Changes an unverified account's address the safe way Firebase supports: a link goes to the
    /// new address, and the account's email changes (verified) only when that link is opened. The
    /// current account and its state are untouched until then.
    func requestEmailChange(to newEmail: String) async throws {
        let token = try await validIDToken(forceRefresh: false)
        let _: OobCodeResponse = try await identityToolkit("accounts:sendOobCode", [
            "requestType": "VERIFY_AND_CHANGE_EMAIL", "idToken": .string(token), "newEmail": .string(newEmail),
        ])
    }

    /// Deletes the signed-in Firebase account: an incomplete, unverified sign-up, or an established
    /// account once the server deleted its data (Profile → Delete account, after `reauthenticate`).
    /// An account that's already gone counts as deleted. Then forgets it here.
    func deleteAccount() async throws {
        do {
            let token = try await validIDToken(forceRefresh: false)
            let _: UpdateResponse = try await identityToolkit("accounts:delete", ["idToken": .string(token)])
        } catch Failure.sessionEnded {
            // USER_NOT_FOUND / INVALID_ID_TOKEN: a previous attempt already deleted it.
        }
        signOut()
    }

    /// Confirms it's this person before deleting the account: signs in again with the account's own
    /// password, which gives the same account a fresh ID token (Firebase and Square Up's server both
    /// require a recent sign-in for deletion). A password for another account changes nothing.
    func reauthenticate(password: String) async throws {
        try requireFirebase()
        guard let current = account, let email = current.email else { throw Failure.signedOut }
        let response: FirebaseTokenResponse = try await identityToolkit("accounts:signInWithPassword", [
            "email": .string(email), "password": .string(password), "returnSecureToken": true,
        ])
        guard response.localId == current.userID else { throw Failure.invalidCredentials }
        renew(current, refreshToken: response.refreshToken, idToken: response.idToken, expiresIn: TimeInterval(response.expiresIn) ?? 3600)
    }

    /// The same, with a code Firebase texted to the account's own verified number
    /// (`FirebasePhoneVerifier`). A sign-in for any other account is refused.
    func reauthenticate(_ phone: PhoneCredentialSession) throws {
        try requireFirebase()
        guard let current = account, current.userID == phone.userID else { throw Failure.invalidCredentials }
        renew(current, refreshToken: phone.refreshToken, idToken: phone.idToken, expiresIn: phone.expiresIn)
    }

    /// New tokens for the signed-in account; everything else known about it stays.
    private func renew(_ current: Account, refreshToken: String, idToken token: String, expiresIn: TimeInterval) {
        var renewed = current
        renewed.refreshToken = refreshToken
        persist(renewed)
        idToken = (token, now().addingTimeInterval(expiresIn))
    }

    /// Saves the name on the Firebase account too, so it can prefill profile setup after
    /// verification (even after a relaunch). Not authoritative: the server profile is.
    func setDisplayName(_ name: String) async throws {
        let token = try await validIDToken(forceRefresh: false)
        let _: UpdateResponse = try await identityToolkit("accounts:update", [
            "idToken": .string(token), "displayName": .string(name), "returnSecureToken": false,
        ])
    }

    /// Records whether the server profile exists, for offline launches.
    func rememberProfile(_ exists: Bool) {
        guard var account else { return }
        account.hasProfile = exists
        persist(account)
    }

    /// The project's password rules. `nil` when Firebase doesn't enforce a policy (its built-in
    /// minimum of 6 characters then applies) or the policy can't be read.
    func passwordPolicy() async -> PasswordPolicy? {
        guard configuration.authMode == .firebase,
              let url = try? endpoint("https://identitytoolkit.googleapis.com/v2/passwordPolicy") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let response: PasswordPolicyResponse = try? await send(request), response.enforcementState == "ENFORCE",
              let options = response.customStrengthOptions else { return nil }
        return PasswordPolicy(
            minimumLength: options.minPasswordLength ?? 6, maximumLength: options.maxPasswordLength,
            requiresLowercase: options.containsLowercaseCharacter ?? false, requiresUppercase: options.containsUppercaseCharacter ?? false,
            requiresNumber: options.containsNumericCharacter ?? false, requiresSymbol: options.containsNonAlphanumericCharacter ?? false
        )
    }

    // MARK: - Demo Mode

    /// Keeps a new demo workspace's credential, replacing whatever account this iPhone had signed in.
    func adoptDemo(_ credential: DemoCredential) throws {
        try requireFirebase()
        signOut()
        demo = credential
        if let data = try? JSONEncoder().encode(credential) { keychain.set(data, for: Self.demoKey) }
    }

    private static func details(_ demo: DemoCredential) -> AccountDetails {
        AccountDetails(userID: demo.userID, email: nil, emailVerified: false, displayName: nil, createdAt: demo.createdAt, isDemo: true)
    }

    func signOut() {
        account = nil
        demo = nil
        keychain.remove(Self.demoKey)
        idToken = nil
        refreshing?.cancel()
        refreshing = nil
        keychain.remove(Self.accountKey)
    }

    // MARK: - Tokens

    private func validIDToken(forceRefresh: Bool) async throws -> String {
        try requireFirebase()
        if !forceRefresh, let idToken, idToken.expiresAt.timeIntervalSince(now()) > 300 { return idToken.value }
        if let refreshing { return try await refreshing.value }
        guard let account else { throw Failure.signedOut }
        let task = Task { () throws -> String in
            let response: SecureTokenResponse = try await secureToken(refreshToken: account.refreshToken)
            guard let seconds = TimeInterval(response.expiresIn) else { throw Failure.unavailable }
            self.updateTokens(id: response.idToken, refresh: response.refreshToken, expiresIn: seconds)
            return response.idToken
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value
        } catch Failure.sessionEnded {
            signOut()
            throw Failure.sessionEnded
        }
    }

    private func updateTokens(id: String, refresh: String, expiresIn: TimeInterval) {
        idToken = (id, now().addingTimeInterval(expiresIn))
        if var account, account.refreshToken != refresh {
            account.refreshToken = refresh
            persist(account)
        }
    }

    private func store(_ response: FirebaseTokenResponse, email: String?) {
        // The same user (an anonymous account upgraded in place) keeps what's known about it.
        let previous = account?.userID == response.localId ? account : nil
        let account = Account(userID: response.localId, email: email ?? response.email ?? previous?.email,
                              refreshToken: response.refreshToken, emailVerified: previous?.emailVerified,
                              createdAt: previous?.createdAt, hasProfile: previous?.hasProfile)
        persist(account)
        idToken = (response.idToken, now().addingTimeInterval(TimeInterval(response.expiresIn) ?? 3600))
    }

    private func persist(_ account: Account) {
        if demo != nil {
            demo = nil
            keychain.remove(Self.demoKey)
        }
        self.account = account
        if let data = try? JSONEncoder().encode(account) { keychain.set(data, for: Self.accountKey) }
    }

    private var developmentUserID: String {
        #if DEBUG
        if let chosen = LaunchConfiguration.current.developmentUserID { return chosen }
        #endif
        if let existing = keychain.string(for: Self.installKey) { return existing }
        let created = "dev-\(UUID().uuidString.lowercased())"
        keychain.set(created, for: Self.installKey)
        return created
    }

    private func requireFirebase() throws {
        guard configuration.authMode == .firebase, configuration.firebaseAPIKey != nil else { throw Failure.notConfigured }
    }

    // MARK: - Firebase REST

    private func identityToolkit<Response: Decodable>(_ method: String, _ body: [String: JSONValue]) async throws -> Response {
        var request = URLRequest(url: try endpoint("https://identitytoolkit.googleapis.com/v1/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func secureToken<Response: Decodable>(refreshToken: String) async throws -> Response {
        var request = URLRequest(url: try endpoint("https://securetoken.googleapis.com/v1/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return try await send(request)
    }

    private func endpoint(_ base: String) throws -> URL {
        guard let key = configuration.firebaseAPIKey, var components = URLComponents(string: base) else { throw Failure.notConfigured }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { throw Failure.notConfigured }
        return url
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw TransportFailure.isOffline(error) || TransportFailure.isTimeout(error) ? Failure.offline : Failure.unavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(FirebaseError.self, from: data))?.error.message ?? ""
            // Only Firebase's error code (e.g. `INVALID_EMAIL`), never the request or the rest of the message.
            Log.sync.error("Account request failed: \(response.statusCode, privacy: .public) \(Self.code(message), privacy: .public)")
            // Any refusal to refresh the token means the stored sign-in no longer works.
            if request.url?.host() == "securetoken.googleapis.com", (400..<500).contains(response.statusCode) { throw Failure.sessionEnded }
            throw Self.failure(for: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.unavailable
        }
    }

    /// Firebase messages look like `WEAK_PASSWORD : Password should be at least 6 characters`.
    private static func code(_ message: String) -> String {
        String(message.prefix { $0 != " " && $0 != ":" })
    }

    static func failure(for message: String) -> Failure {
        switch code(message) {
        case "EMAIL_EXISTS": .emailInUse
        case "INVALID_EMAIL", "MISSING_EMAIL": .invalidEmail
        case "WEAK_PASSWORD", "MISSING_PASSWORD", "PASSWORD_DOES_NOT_MEET_REQUIREMENTS": .weakPassword
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS": .invalidCredentials
        case "USER_DISABLED": .accountDisabled
        case "TOO_MANY_ATTEMPTS_TRY_LATER", "QUOTA_EXCEEDED": .tooManyAttempts
        case "OPERATION_NOT_ALLOWED", "PASSWORD_LOGIN_DISABLED", "ADMIN_ONLY_OPERATION": .operationNotAllowed
        case "CREDENTIAL_TOO_OLD_LOGIN_AGAIN", "REQUIRES_RECENT_LOGIN": .recentSignInRequired
        case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_NOT_FOUND", "INVALID_ID_TOKEN": .sessionEnded
        case "INVALID_PHONE_NUMBER", "MISSING_PHONE_NUMBER": .invalidPhoneNumber
        case "INVALID_CODE", "MISSING_CODE": .invalidCode
        case "SESSION_EXPIRED", "INVALID_SESSION_INFO", "MISSING_SESSION_INFO", "INVALID_TEMPORARY_PROOF": .codeExpired
        case "PHONE_NUMBER_EXISTS", "CREDENTIAL_ALREADY_IN_USE": .phoneInUse
        default: .unavailable
        }
    }
}

// MARK: - Firebase REST responses (Identity Toolkit and Secure Token)

private nonisolated struct FirebaseTokenResponse: Decodable {
    let idToken: String
    let refreshToken: String
    let expiresIn: String
    let localId: String
    let email: String?
}

private nonisolated struct OobCodeResponse: Decodable {
    let email: String?
}

private nonisolated struct UpdateResponse: Decodable {
    let localId: String?
}

private nonisolated struct LookupResponse: Decodable {
    struct User: Decodable {
        let localId: String
        let email: String?
        let emailVerified: Bool?
        let displayName: String?
        let createdAt: String?
        let phoneNumber: String?
    }

    let users: [User]?
}

private nonisolated struct PhoneLinkResponse: Decodable {
    let idToken: String?
    let refreshToken: String?
    let expiresIn: String?
    let localId: String?
    let phoneNumber: String?
    let temporaryProof: String?
}

private nonisolated struct PasswordPolicyResponse: Decodable {
    struct Options: Decodable {
        let minPasswordLength: Int?
        let maxPasswordLength: Int?
        let containsLowercaseCharacter: Bool?
        let containsUppercaseCharacter: Bool?
        let containsNumericCharacter: Bool?
        let containsNonAlphanumericCharacter: Bool?
    }

    let customStrengthOptions: Options?
    let enforcementState: String?
}

private nonisolated struct SecureTokenResponse: Decodable {
    let idToken: String
    let refreshToken: String
    let expiresIn: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private nonisolated struct FirebaseError: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
