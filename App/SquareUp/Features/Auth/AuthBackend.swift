import Foundation
import os

/// Why an account step didn't work, in terms the launch flow can act on.
nonisolated enum AuthFailure: Error, Equatable, Sendable {
    /// From Firebase Authentication (invalid credentials, offline, rate limits…).
    case account(AccountSession.Failure)
    /// From Square Up's server (saving the profile), already in plain language.
    case server(String)

    var message: String {
        switch self {
        case .account(let failure): LedgerErrorMessages.text(for: failure)
        case .server(let message): message
        }
    }

    var isOffline: Bool { self == .account(.offline) }
    var isSessionEnded: Bool { self == .account(.sessionEnded) || self == .account(.signedOut) }
}

/// A phone sign-in: the account, and whether Firebase created it just now.
nonisolated struct PhoneSignInResult: Equatable, Sendable {
    let details: AccountSession.AccountDetails
    let isNewUser: Bool
}

/// The name other people see, from the server profile.
nonisolated struct AuthProfile: Equatable, Sendable {
    let memberID: String
    let displayName: String
}

/// Everything the launch flow needs from accounts, profiles, and the device. `LiveAuthBackend`
/// talks to Firebase and Square Up's server; tests and UI tests substitute fakes, so automated runs
/// never create Firebase users or send email.
@MainActor
protocol AuthBackend: AnyObject {
    /// The account kept on this iPhone (no network request).
    func storedAccount() async -> AccountSession.StoredAccount?
    /// Refreshes the stored session and reads the account from Firebase.
    func restore() async throws(AuthFailure) -> AccountSession.AccountDetails
    /// Creates an email account (upgrading an older anonymous one in place) and saves the name on it.
    func signUp(email: String, password: String, displayName: String) async throws(AuthFailure) -> AccountSession.AccountDetails
    func signIn(email: String, password: String) async throws(AuthFailure) -> AccountSession.AccountDetails
    /// Reads the account again (verification status).
    func reload() async throws(AuthFailure) -> AccountSession.AccountDetails
    func sendVerificationEmail() async throws(AuthFailure)
    /// Sends a link to `newEmail`; the unverified account's address changes only when it's opened.
    func requestEmailChange(to newEmail: String) async throws(AuthFailure)
    /// Deletes the signed-in account — only an incomplete sign-up (unverified, no profile).
    func deleteIncompleteAccount() async throws(AuthFailure)
    func sendPasswordReset(email: String) async throws(AuthFailure)
    func passwordPolicy() async -> AccountSession.PasswordPolicy?
    /// Whether this build can verify phone numbers (Firebase's iOS app is configured).
    var isPhoneSignInAvailable: Bool { get }
    /// Sends a code to an E.164 number (Firebase); returns the verification ID.
    func sendPhoneCode(to phoneNumber: String) async throws(AuthFailure) -> String
    /// Signs in to — or creates — the number's account with the code, and opens its local space.
    func signIn(phoneVerificationID: String, code: String) async throws(AuthFailure) -> PhoneSignInResult
    /// Adds a verified number to the signed-in account (never a second account).
    func linkPhone(verificationID: String, code: String) async throws(AuthFailure) -> AccountSession.AccountDetails
    /// The server profile, or `nil` when this account hasn't chosen a name yet.
    func loadProfile() async throws(AuthFailure) -> AuthProfile?
    /// The profile saved on this iPhone the last time it was confirmed (offline launches).
    func cachedProfile() async -> AuthProfile?
    func saveProfile(displayName: String) async throws(AuthFailure) -> AuthProfile
    /// Gets the app ready for this person: their place in this iPhone's ledger and shared groups.
    func prepareApp(for profile: AuthProfile) async
    /// Changes waiting to be sent in shared groups (signing out discards them).
    var unsentChangeCount: Int { get }
    func signOut() async

    // MARK: Demo Mode

    /// Whether "Enter Demo" can start a demo workspace (the build has Square Up's server).
    var isDemoAvailable: Bool { get }
    /// Starts this iPhone's own demo workspace of fictional sample data and opens its local space.
    func enterDemo() async throws(AuthFailure) -> AccountSession.AccountDetails
    /// Restores the open demo workspace to its seed, on the server and on this iPhone.
    func resetDemo() async throws(AuthFailure) -> AuthProfile
    /// Deletes the demo workspace (server and iPhone) and signs out of it.
    func leaveDemo() async

    // MARK: Deleting an account

    /// What deleting the signed-in account would do now, and anything to finish first.
    func accountDeletionPlan() async throws(AuthFailure) -> AccountDeletionPlan
    /// Signs in again with the account's password (a fresh sign-in for deleting it).
    func reauthenticate(password: String) async throws(AuthFailure)
    /// Sends a code to the account's own verified number, to sign in again before deleting it.
    func sendReauthenticationCode() async throws(AuthFailure) -> String
    /// Signs in again with that code.
    func reauthenticate(phoneVerificationID: String, code: String) async throws(AuthFailure)
    /// Deletes the account: its data on the server, then its Firebase sign-in, then everything this
    /// iPhone keeps for it. Needs a fresh sign-in (`reauthenticate`) just before.
    func deleteAccount() async throws(AuthFailure) -> AccountDeletionOutcome
}

/// Backends without Demo Mode (test stand-ins) don't offer it.
extension AuthBackend {
    var isDemoAvailable: Bool { false }

    func enterDemo() async throws(AuthFailure) -> AccountSession.AccountDetails {
        throw .account(.notConfigured)
    }

    func resetDemo() async throws(AuthFailure) -> AuthProfile {
        throw .account(.notConfigured)
    }

    func leaveDemo() async {
        await signOut()
    }

    func accountDeletionPlan() async throws(AuthFailure) -> AccountDeletionPlan {
        throw .account(.notConfigured)
    }

    func reauthenticate(password: String) async throws(AuthFailure) {
        throw .account(.notConfigured)
    }

    func sendReauthenticationCode() async throws(AuthFailure) -> String {
        throw .account(.notConfigured)
    }

    func reauthenticate(phoneVerificationID: String, code: String) async throws(AuthFailure) {
        throw .account(.notConfigured)
    }

    func deleteAccount() async throws(AuthFailure) -> AccountDeletionOutcome {
        throw .account(.notConfigured)
    }
}

/// Firebase Authentication (REST for email, the SDK for phone verification) plus Square Up's
/// account endpoint, with each account's local data opened in its own scope (`AppSession`) once
/// Firebase confirms who it is.
@MainActor
final class LiveAuthBackend: AuthBackend {
    private let account: AccountSession
    private let session: AppSession
    private let phone: (any PhoneVerifying)?
    private let demo: DemoWorkspaceAPI?
    private let deletion: AccountDeletionAPI?
    private let now: () -> Date

    init(account: AccountSession, session: AppSession, phone: (any PhoneVerifying)? = nil, demo: DemoWorkspaceAPI? = nil,
         deletion: AccountDeletionAPI? = nil, now: @escaping () -> Date = { .now }) {
        self.account = account
        self.session = session
        self.phone = phone
        self.demo = demo
        self.deletion = deletion
        self.now = now
    }

    func storedAccount() async -> AccountSession.StoredAccount? {
        await account.storedAccount
    }

    func restore() async throws(AuthFailure) -> AccountSession.AccountDetails {
        let details = try await call { try await $0.restore() }
        try open(details.userID, isDemo: details.isDemo)
        return details
    }

    func signUp(email: String, password: String, displayName: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        try await call { try await $0.addEmail(email, password: password) }
        // The name travels with the Firebase account so profile setup can offer it after verification.
        try? await account.setDisplayName(displayName)
        let details: AccountSession.AccountDetails
        if let looked = try? await account.lookup() {
            details = looked
        } else {
            let stored = await account.storedAccount
            details = AccountSession.AccountDetails(userID: stored?.userID ?? "", email: email, emailVerified: false, displayName: displayName,
                                                    createdAt: now())
        }
        try open(details.userID)
        return details
    }

    func signIn(email: String, password: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        try await call { try await $0.signIn(email: email, password: password) }
        let details = try await call { try await $0.lookup() }
        try open(details.userID)
        return details
    }

    func reload() async throws(AuthFailure) -> AccountSession.AccountDetails {
        let details = try await call { try await $0.lookup() }
        // A newly verified address: get an ID token that says so (the server checks the claim).
        if details.emailVerified { _ = try? await account.authorizationHeader(forceRefresh: true) }
        return details
    }

    func sendVerificationEmail() async throws(AuthFailure) {
        try await call { try await $0.sendEmailVerification() }
    }

    func requestEmailChange(to newEmail: String) async throws(AuthFailure) {
        try await call { try await $0.requestEmailChange(to: newEmail) }
    }

    func deleteIncompleteAccount() async throws(AuthFailure) {
        try await call { try await $0.deleteAccount() }
        session.close()
    }

    func sendPasswordReset(email: String) async throws(AuthFailure) {
        try await call { try await $0.sendPasswordReset(email: email) }
    }

    func passwordPolicy() async -> AccountSession.PasswordPolicy? {
        await account.passwordPolicy()
    }

    // MARK: Phone

    var isPhoneSignInAvailable: Bool { phone != nil }

    func sendPhoneCode(to phoneNumber: String) async throws(AuthFailure) -> String {
        guard let phone else { throw .account(.notConfigured) }
        do {
            return try await phone.sendCode(to: phoneNumber)
        } catch {
            throw .account(error)
        }
    }

    /// Firebase signs in with the code; the session then moves into `AccountSession`, exactly
    /// where an email sign-in lives, and the account's own local space opens.
    func signIn(phoneVerificationID: String, code: String) async throws(AuthFailure) -> PhoneSignInResult {
        guard let phone else { throw .account(.notConfigured) }
        let credential: PhoneCredentialSession
        do {
            credential = try await phone.signIn(verificationID: phoneVerificationID, code: code)
        } catch {
            throw .account(error)
        }
        try await call { try await $0.adopt(credential) }
        let details = try await call { try await $0.lookup() }
        try open(details.userID)
        return PhoneSignInResult(details: details, isNewUser: credential.isNewUser)
    }

    func linkPhone(verificationID: String, code: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        try await call { try await $0.linkPhone(verificationID: verificationID, code: code) }
    }

    func loadProfile() async throws(AuthFailure) -> AuthProfile? {
        let groups = try scope().sharedGroups
        do {
            let profile = try await groups.loadAccount()
            await account.rememberProfile(profile != nil)
            return profile.map { AuthProfile(memberID: $0.memberId, displayName: $0.displayName) }
        } catch {
            throw Self.failure(error)
        }
    }

    func cachedProfile() async -> AuthProfile? {
        // Offline launch: open the remembered account's own space and read its saved profile.
        guard let stored = await account.storedAccount, (try? open(stored.userID, isDemo: stored.isDemo)) != nil,
              let groups = session.scope?.sharedGroups, let profile = groups.cache.account(stored.userID)?.profile else { return nil }
        return AuthProfile(memberID: profile.memberId, displayName: profile.displayName)
    }

    func saveProfile(displayName: String) async throws(AuthFailure) -> AuthProfile {
        let groups = try scope().sharedGroups
        do {
            try await groups.saveProfile(displayName: displayName)
        } catch {
            if case .remote(let issue) = error, issue == .offline { throw .account(.offline) }
            throw .server(LedgerErrorMessages.text(for: error))
        }
        await account.rememberProfile(true)
        guard let profile = groups.profile else { throw .server(LedgerErrorMessages.text(for: .remote(.unavailable))) }
        return AuthProfile(memberID: profile.memberId, displayName: profile.displayName)
    }

    func prepareApp(for profile: AuthProfile) async {
        guard let scope = session.scope else { return }
        if let identity = scope.store as? any LocalIdentityPreparing, let memberID = MemberID(string: profile.memberID) {
            try? await identity.prepareCurrentUser(id: memberID, displayName: profile.displayName)
        }
        await scope.sharing.refreshAccountStatus()
        await scope.sharedGroups.refreshGroups()
    }

    var unsentChangeCount: Int { session.scope?.sharedGroups.unsentChangeCount ?? 0 }

    /// Closes this account's local space (kept for when it signs in again) and forgets the sign-in.
    /// A demo workspace's local copy isn't kept: it's removed from this iPhone.
    func signOut() async {
        let demoUserID = await account.isDemo ? await account.userID : nil
        session.close()
        await account.signOut()
        if let demoUserID { session.discardLocalData(uid: demoUserID) }
    }

    // MARK: Demo Mode

    var isDemoAvailable: Bool { demo != nil }

    /// The server creates this iPhone's own workspace and credential; its local space opens empty
    /// and fills from the server like any account's shared groups.
    func enterDemo() async throws(AuthFailure) -> AccountSession.AccountDetails {
        guard let demo else { throw .account(.notConfigured) }
        let started: DemoSessionDTO
        do {
            started = try await demo.start()
        } catch {
            throw Self.failure(error)
        }
        let credential = AccountSession.DemoCredential(userID: started.userId, token: started.token, createdAt: now(),
                                                       expiresAt: started.expiresAt.flatMap(Self.serverDate))
        try await call { try await $0.adoptDemo(credential) }
        let details = try await call { try await $0.restore() }
        try open(details.userID, isDemo: true)
        Log.app.info("Entered a demo workspace")
        return details
    }

    /// The server puts the seed back; this iPhone's copy (and anything made only here) is removed and
    /// the workspace reopens from the server.
    func resetDemo() async throws(AuthFailure) -> AuthProfile {
        guard let demo, await account.isDemo, let userID = await account.userID else { throw .account(.signedOut) }
        let profile: ProfileDTO
        do {
            profile = try await demo.reset()
        } catch {
            throw Self.failure(error)
        }
        session.discardLocalData(uid: userID)
        try open(userID, isDemo: true)
        _ = try? await session.scope?.sharedGroups.loadAccount()
        let restored = AuthProfile(memberID: profile.memberId, displayName: profile.displayName)
        await prepareApp(for: restored)
        Log.app.info("Reset the demo workspace")
        return restored
    }

    /// Deletes the workspace on the server (it would go within a week anyway), then signs out of it.
    func leaveDemo() async {
        if await account.isDemo, let demo { try? await demo.end() }
        await signOut()
    }

    // MARK: Deleting an account

    func accountDeletionPlan() async throws(AuthFailure) -> AccountDeletionPlan {
        guard let deletion else { throw .account(.notConfigured) }
        do {
            return try await deletion.plan()
        } catch {
            throw Self.failure(error)
        }
    }

    func reauthenticate(password: String) async throws(AuthFailure) {
        try await call { try await $0.reauthenticate(password: password) }
    }

    func sendReauthenticationCode() async throws(AuthFailure) -> String {
        guard let number = await account.storedAccount?.phoneNumber else { throw .account(.signedOut) }
        return try await sendPhoneCode(to: number)
    }

    func reauthenticate(phoneVerificationID: String, code: String) async throws(AuthFailure) {
        guard let phone else { throw .account(.notConfigured) }
        let credential: PhoneCredentialSession
        do {
            credential = try await phone.signIn(verificationID: phoneVerificationID, code: code)
        } catch {
            throw .account(error)
        }
        try await call { try await $0.reauthenticate(credential) }
    }

    /// The server deletes the account's data first (it checks the sign-in is recent and nothing is
    /// left to settle), then Firebase deletes the sign-in, then this iPhone forgets everything it kept
    /// for the account. A failure after the server step is safe to retry: it repeats harmlessly.
    func deleteAccount() async throws(AuthFailure) -> AccountDeletionOutcome {
        guard let deletion, !(await account.isDemo), let userID = await account.userID else { throw .account(.signedOut) }
        do {
            try await deletion.delete()
        } catch {
            if error.code == "recent_sign_in_required" { throw .account(.recentSignInRequired) }
            throw Self.failure(error)
        }
        do {
            try await account.deleteAccount()
        } catch {
            // The server's part is done (repeating it is harmless); only the sign-in is left. This
            // iPhone's copy stays until it's gone, so trying again finishes everything.
            let reason = (error as? AccountSession.Failure).map { LedgerErrorMessages.text(for: $0) } ?? ""
            throw .server(String(localized: """
            Your Square Up data was deleted, but removing your sign-in didn't finish. \(reason) Tap Delete account again to finish.
            """))
        }
        let removed = session.discardLocalData(uid: userID)
        Log.app.info("Deleted an account (this iPhone's copy \(removed ? "removed" : "partly left", privacy: .public))")
        return removed ? .complete : .localDataRemains
    }

    private static func serverDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
    }

    private func open(_ userID: String, isDemo: Bool = false) throws(AuthFailure) {
        guard !userID.isEmpty else { throw .account(.unavailable) }
        do {
            try session.open(uid: userID, isDemo: isDemo)
        } catch {
            throw .server(String(localized: "Square Up couldn't open this account's data on this iPhone. Restart the app and try again."))
        }
    }

    private func scope() throws(AuthFailure) -> AccountScope {
        guard let scope = session.scope else { throw .account(.signedOut) }
        return scope
    }

    private func call<T>(_ body: (AccountSession) async throws -> T) async throws(AuthFailure) -> T {
        do {
            return try await body(account)
        } catch let failure as AccountSession.Failure {
            throw .account(failure)
        } catch {
            throw .account(.unavailable)
        }
    }

    private static func failure(_ error: RemoteError) -> AuthFailure {
        switch error {
        case .offline, .timedOut: .account(.offline)
        case .account(let failure): .account(failure)
        case .server(let refusal) where refusal.code == "unauthenticated": .account(.sessionEnded)
        default: .server(LedgerErrorMessages.text(for: LedgerError.from(error)))
        }
    }
}

/// A ledger that can make the signed-in person its current user (a new account's empty ledger).
protocol LocalIdentityPreparing {
    func prepareCurrentUser(id: MemberID, displayName: String) async throws
}
