#if DEBUG
import Foundation

/// DEBUG only: an in-process stand-in for Firebase and the account endpoint, selected with
/// `-SUAuthDemo <scenario>` so UI tests can walk the launch flow — and switch between accounts —
/// without creating real users, sending real email, or sending a text message. Never compiled into
/// release builds.
///
/// Each email address or phone number is its own account (its own UID, so its own local space
/// through `AppSession`), and accounts are remembered for the whole launch.
///
/// - `fresh`: nothing on this iPhone (Welcome).
/// - `unverified`: signed in, address not yet verified, no profile.
/// - `noProfile`: verified, no name chosen yet.
/// - `signedIn`: verified with a profile (opens the app).
/// - `signedInWithPhone`: a phone account with a profile (opens the app).
/// - `unverifiedWithProfile`: never verified but already has a profile — still stops at "Check
///   your email"; no account opens the app unverified.
/// - `sessionEnded`: the stored sign-in is refused at launch.
/// - `offline`: verified with a profile, but the service can't be reached at launch.
///
/// Sign-up refuses `taken@example.com`; sign-in refuses the password `wrong-password` and treats
/// `unverified@example.com` as unverified. A pending verification (or email change) completes on
/// the second check (the first shows "not yet").
///
/// Phone numbers follow Firebase's fictional test numbers: every number is accepted, the code is
/// always `123456` (`000000` is wrong, `999999` has expired), and `+1 650-555-1234` already has an
/// account with a profile (Riley). `+1 650-555-0000` hits the SMS quota.
@MainActor
final class DemoAuthBackend: AuthBackend {
    enum Scenario: String {
        case fresh, unverified, noProfile, signedIn, signedInWithPhone, unverifiedWithProfile, sessionEnded, offline
    }

    private struct DemoAccount {
        let uid: String
        var email: String?
        var phone: String?
        var verified: Bool
        var createdAt: Date
        var profile: AuthProfile?
        var pendingEmail: String?
        var checks = 0

        init(email: String, verified: Bool, createdAt: Date, profile: AuthProfile? = nil) {
            uid = "demo-\(email.lowercased())"
            self.email = email
            self.verified = verified
            self.createdAt = createdAt
            self.profile = profile
        }

        init(phone: String, createdAt: Date, profile: AuthProfile? = nil) {
            uid = "demo-phone-\(phone.filter(\.isNumber))"
            self.phone = phone
            verified = false
            self.createdAt = createdAt
            self.profile = profile
        }
    }

    static let existingPhone = "+16505551234"
    static let quotaPhone = "+16505550000"
    static let validCode = "123456"

    private let session: AppSession
    private var accounts: [String: DemoAccount] = [:]
    private var current: String?
    private var restoreFailure: AuthFailure?
    /// Sent codes by verification ID (the number they went to).
    private var sentCodes: [String: String] = [:]
    /// After the verification requirement (new accounts) and before it (existing ones).
    private static let newAccountDate = Date(timeIntervalSince1970: 1_791_500_000)

    init?(argument: String, session: AppSession) {
        guard let scenario = Scenario(rawValue: argument) else { return nil }
        self.session = session
        let riley = DemoAccount(phone: Self.existingPhone, createdAt: Self.newAccountDate, profile: Self.profile(for: "riley@example.com"))
        accounts[riley.uid] = riley
        switch scenario {
        case .fresh:
            break
        case .unverified:
            remember(DemoAccount(email: "maya@example.com", verified: false, createdAt: Self.newAccountDate))
        case .noProfile:
            remember(DemoAccount(email: "maya@example.com", verified: true, createdAt: Self.newAccountDate))
        case .signedIn:
            remember(Self.established("riley@example.com", verified: true))
        case .signedInWithPhone:
            current = riley.uid
        case .unverifiedWithProfile:
            remember(Self.established("riley@example.com", verified: false))
        case .sessionEnded:
            remember(Self.established("riley@example.com", verified: true))
            restoreFailure = .account(.sessionEnded)
        case .offline:
            remember(Self.established("riley@example.com", verified: true))
            restoreFailure = .account(.offline)
        }
    }

    private static func established(_ email: String, verified: Bool) -> DemoAccount {
        DemoAccount(email: email, verified: verified, createdAt: newAccountDate, profile: profile(for: email))
    }

    /// "riley@example.com" → "Riley Park"-style names, stable per address.
    private static func profile(for email: String) -> AuthProfile {
        let name = email.split(separator: "@").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Friend"
        let digest = abs(email.lowercased().hashValue) % 0xFFFF_FFFF
        return AuthProfile(memberID: String(format: "8f1c2d3e-0000-4000-8000-%012x", digest), displayName: "\(name) Example")
    }

    private func remember(_ account: DemoAccount) {
        accounts[account.uid] = account
        current = account.uid
    }

    func storedAccount() async -> AccountSession.StoredAccount? {
        guard let account = current.flatMap({ accounts[$0] }) else { return nil }
        return AccountSession.StoredAccount(userID: account.uid, email: account.email, emailVerified: account.verified, createdAt: account.createdAt,
                                            hasProfile: account.profile != nil, phoneNumber: account.phone)
    }

    func restore() async throws(AuthFailure) -> AccountSession.AccountDetails {
        if let restoreFailure {
            self.restoreFailure = nil
            if restoreFailure.isOffline, let uid = current { _ = try? session.open(uid: uid) }
            throw restoreFailure
        }
        return try openCurrent()
    }

    func signUp(email: String, password: String, displayName: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        await pause()
        if email.lowercased() == "taken@example.com" || accounts["demo-\(email.lowercased())"] != nil { throw .account(.emailInUse) }
        remember(DemoAccount(email: email, verified: false, createdAt: Self.newAccountDate))
        var details = try openCurrent()
        details = AccountSession.AccountDetails(userID: details.userID, email: details.email, emailVerified: false, displayName: displayName,
                                                createdAt: details.createdAt)
        return details
    }

    func signIn(email: String, password: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        await pause()
        if password == "wrong-password" { throw .account(.invalidCredentials) }
        let uid = "demo-\(email.lowercased())"
        if accounts[uid] == nil {
            let verified = email.lowercased() != "unverified@example.com"
            accounts[uid] = verified ? Self.established(email, verified: true) : DemoAccount(email: email, verified: false, createdAt: Self.newAccountDate)
        }
        current = uid
        return try openCurrent()
    }

    func reload() async throws(AuthFailure) -> AccountSession.AccountDetails {
        await pause()
        guard let uid = current, var account = accounts[uid] else { throw .account(.signedOut) }
        account.checks += 1
        if account.checks >= 2 {
            if let pending = account.pendingEmail {
                account.email = pending
                account.pendingEmail = nil
            }
            account.verified = true
        }
        accounts[uid] = account
        return details(account)
    }

    func sendVerificationEmail() async throws(AuthFailure) { await pause() }

    func requestEmailChange(to newEmail: String) async throws(AuthFailure) {
        await pause()
        guard let uid = current, var account = accounts[uid] else { throw .account(.signedOut) }
        if newEmail.lowercased() == "taken@example.com" { throw .account(.emailInUse) }
        account.pendingEmail = newEmail
        account.checks = 0
        accounts[uid] = account
    }

    func deleteIncompleteAccount() async throws(AuthFailure) {
        await pause()
        if let uid = current { accounts[uid] = nil }
        current = nil
        session.close()
    }

    func sendPasswordReset(email: String) async throws(AuthFailure) { await pause() }
    func passwordPolicy() async -> AccountSession.PasswordPolicy? { nil }

    // MARK: - Phone

    var isPhoneSignInAvailable: Bool { true }

    func sendPhoneCode(to phoneNumber: String) async throws(AuthFailure) -> String {
        await pause()
        if phoneNumber == Self.quotaPhone { throw .account(.smsQuotaExceeded) }
        let id = "demo-verification-\(sentCodes.count + 1)"
        sentCodes[id] = phoneNumber
        return id
    }

    func signIn(phoneVerificationID: String, code: String) async throws(AuthFailure) -> PhoneSignInResult {
        await pause()
        let number = try checkCode(phoneVerificationID, code)
        let uid = "demo-phone-\(number.filter(\.isNumber))"
        let isNew = accounts[uid] == nil
        if isNew { accounts[uid] = DemoAccount(phone: number, createdAt: Self.newAccountDate) }
        current = uid
        return try PhoneSignInResult(details: openCurrent(), isNewUser: isNew)
    }

    func linkPhone(verificationID: String, code: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        await pause()
        let number = try checkCode(verificationID, code)
        guard let uid = current, var account = accounts[uid] else { throw .account(.signedOut) }
        if accounts.values.contains(where: { $0.phone == number && $0.uid != uid }) { throw .account(.phoneInUse) }
        account.phone = number
        accounts[uid] = account
        return details(account)
    }

    private func checkCode(_ verificationID: String, _ code: String) throws(AuthFailure) -> String {
        guard let number = sentCodes[verificationID] else { throw .account(.codeExpired) }
        switch code {
        case Self.validCode: return number
        case "999999": throw .account(.codeExpired)
        default: throw .account(.invalidCode)
        }
    }

    // MARK: - Profile

    func loadProfile() async throws(AuthFailure) -> AuthProfile? {
        current.flatMap { accounts[$0]?.profile }
    }

    func cachedProfile() async -> AuthProfile? { current.flatMap { accounts[$0]?.profile } }

    func saveProfile(displayName: String) async throws(AuthFailure) -> AuthProfile {
        await pause()
        guard let uid = current, var account = accounts[uid] else { throw .account(.signedOut) }
        let saved = AuthProfile(memberID: Self.profile(for: account.email ?? uid).memberID, displayName: displayName)
        account.profile = saved
        accounts[uid] = account
        return saved
    }

    func prepareApp(for profile: AuthProfile) async {
        if let identity = session.scope?.store as? any LocalIdentityPreparing, let id = MemberID(string: profile.memberID) {
            try? await identity.prepareCurrentUser(id: id, displayName: profile.displayName)
        }
    }

    var unsentChangeCount: Int { 0 }

    func signOut() async {
        session.close()
        current = nil
    }

    private func openCurrent() throws(AuthFailure) -> AccountSession.AccountDetails {
        guard let uid = current, let account = accounts[uid] else { throw .account(.signedOut) }
        do {
            try session.open(uid: uid)
        } catch {
            throw .account(.unavailable)
        }
        return details(account)
    }

    private func details(_ account: DemoAccount) -> AccountSession.AccountDetails {
        AccountSession.AccountDetails(userID: account.uid, email: account.email, emailVerified: account.email != nil && account.verified,
                                      displayName: nil, createdAt: account.createdAt, phoneNumber: account.phone)
    }

    /// A short pause so progress states are visible (and testable) as with the real service.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(300))
    }
}
#endif
