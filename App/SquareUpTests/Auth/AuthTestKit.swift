import Foundation
@testable import SquareUp

/// A scriptable `AuthBackend`: every answer is set by the test and every call is counted.
/// Nothing here talks to Firebase or the server.
@MainActor
final class FakeAuthBackend: AuthBackend {
    var stored: AccountSession.StoredAccount?
    var restoreResult: Result<AccountSession.AccountDetails, AuthFailure> = .failure(.account(.signedOut))
    var signUpResult: Result<AccountSession.AccountDetails, AuthFailure> = .success(AuthFixtures.newAccount)
    var signInResult: Result<AccountSession.AccountDetails, AuthFailure> = .success(AuthFixtures.verified)
    /// Answers for successive `reload()` calls; the last one repeats.
    var reloadResults: [Result<AccountSession.AccountDetails, AuthFailure>] = [.success(AuthFixtures.newAccount)]
    var verificationResult: Result<Void, AuthFailure> = .success(())
    /// Answers for successive email-change requests and deletions; the last one repeats.
    var emailChangeResults: [Result<Void, AuthFailure>] = [.success(())]
    var deleteResults: [Result<Void, AuthFailure>] = [.success(())]
    var resetResult: Result<Void, AuthFailure> = .success(())
    var policy: AccountSession.PasswordPolicy?
    var profileResult: Result<AuthProfile?, AuthFailure> = .success(AuthFixtures.profile)
    var cached: AuthProfile?
    var saveResult: Result<AuthProfile, AuthFailure> = .success(AuthFixtures.profile)
    var unsentChangeCount = 0
    /// When set, sign-up and sign-in wait here until the test lets them continue.
    var hold: AsyncStream<Void>?
    /// Phone sign-in (off unless a test turns it on, as in a build without Firebase's iOS app).
    var isPhoneSignInAvailable = false
    /// Answers for successive code sends; the last one repeats.
    var sendCodeResults: [Result<String, AuthFailure>] = [.success("verification-1")]
    var phoneSignInResult: Result<PhoneSignInResult, AuthFailure> = .success(PhoneSignInResult(details: AuthFixtures.phoneAccount, isNewUser: true))
    var linkResult: Result<AccountSession.AccountDetails, AuthFailure> = .success(AuthFixtures.verifiedWithPhone)
    private(set) var sentNumbers: [String] = []
    private(set) var enteredCodes: [String] = []

    private(set) var calls: [String] = []
    private(set) var preparedProfiles: [AuthProfile] = []

    func count(_ name: String) -> Int { calls.count { $0 == name } }

    func storedAccount() async -> AccountSession.StoredAccount? {
        calls.append("stored")
        return stored
    }

    func restore() async throws(AuthFailure) -> AccountSession.AccountDetails {
        calls.append("restore")
        return try restoreResult.get()
    }

    func signUp(email: String, password: String, displayName: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        calls.append("signUp")
        await waitIfHeld()
        return try signUpResult.get()
    }

    func signIn(email: String, password: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        calls.append("signIn")
        await waitIfHeld()
        return try signInResult.get()
    }

    func reload() async throws(AuthFailure) -> AccountSession.AccountDetails {
        calls.append("reload")
        let result = reloadResults.count > 1 ? reloadResults.removeFirst() : reloadResults[0]
        return try result.get()
    }

    func sendVerificationEmail() async throws(AuthFailure) {
        calls.append("sendVerification")
        try verificationResult.get()
    }

    func requestEmailChange(to newEmail: String) async throws(AuthFailure) {
        calls.append("changeEmail")
        let result = emailChangeResults.count > 1 ? emailChangeResults.removeFirst() : emailChangeResults[0]
        try result.get()
    }

    func deleteIncompleteAccount() async throws(AuthFailure) {
        calls.append("delete")
        let result = deleteResults.count > 1 ? deleteResults.removeFirst() : deleteResults[0]
        try result.get()
        stored = nil
    }

    func sendPasswordReset(email: String) async throws(AuthFailure) {
        calls.append("sendReset")
        try resetResult.get()
    }

    func passwordPolicy() async -> AccountSession.PasswordPolicy? {
        calls.append("policy")
        return policy
    }

    func loadProfile() async throws(AuthFailure) -> AuthProfile? {
        calls.append("loadProfile")
        return try profileResult.get()
    }

    func cachedProfile() async -> AuthProfile? { cached }

    func saveProfile(displayName: String) async throws(AuthFailure) -> AuthProfile {
        calls.append("saveProfile")
        return try saveResult.get()
    }

    func prepareApp(for profile: AuthProfile) async {
        calls.append("prepareApp")
        preparedProfiles.append(profile)
    }

    func signOut() async {
        calls.append("signOut")
        stored = nil
    }

    func sendPhoneCode(to phoneNumber: String) async throws(AuthFailure) -> String {
        calls.append("sendCode")
        let result = sendCodeResults.count > 1 ? sendCodeResults.removeFirst() : sendCodeResults[0]
        let id = try result.get()
        sentNumbers.append(phoneNumber)
        return id
    }

    func signIn(phoneVerificationID: String, code: String) async throws(AuthFailure) -> PhoneSignInResult {
        calls.append("phoneSignIn")
        enteredCodes.append(code)
        return try phoneSignInResult.get()
    }

    func linkPhone(verificationID: String, code: String) async throws(AuthFailure) -> AccountSession.AccountDetails {
        calls.append("linkPhone")
        return try linkResult.get()
    }

    private func waitIfHeld() async {
        guard let hold else { return }
        for await _ in hold { break }
    }
}

nonisolated enum AuthFixtures {
    static let created = Date(timeIntervalSince1970: 1_791_500_000)
    static let profile = AuthProfile(memberID: "7d1f0000-0000-4000-8000-0000000000a1", displayName: "Maya Chen")

    static let verified = AccountSession.AccountDetails(userID: "uid-maya", email: "maya@example.com", emailVerified: true,
                                                        displayName: "Maya Chen", createdAt: created)
    /// A phone account: verified by its code, no email.
    static let phoneAccount = AccountSession.AccountDetails(userID: "uid-phone", email: nil, emailVerified: false, displayName: nil,
                                                            createdAt: created, phoneNumber: "+16505553434")
    /// Maya's email account after adding a phone number.
    static let verifiedWithPhone = AccountSession.AccountDetails(userID: "uid-maya", email: "maya@example.com", emailVerified: true,
                                                                 displayName: "Maya Chen", createdAt: created, phoneNumber: "+16505553434")
    /// A new account, not yet verified.
    static let newAccount = AccountSession.AccountDetails(userID: "uid-maya", email: "maya@example.com", emailVerified: false,
                                                          displayName: "Maya Chen", createdAt: created)
    /// An account created long ago and never verified: age earns no exception.
    static let oldUnverifiedAccount = AccountSession.AccountDetails(userID: "uid-riley", email: "riley@example.com", emailVerified: false,
                                                                    displayName: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    static func stored(verified: Bool?, createdAt: Date? = created, hasProfile: Bool? = true,
                       email: String? = "maya@example.com") -> AccountSession.StoredAccount {
        AccountSession.StoredAccount(userID: "uid-maya", email: email, emailVerified: verified, createdAt: createdAt, hasProfile: hasProfile)
    }

    static var form: SignUpForm {
        SignUpForm(name: "  Maya Chen ", email: " maya@example.com ", password: "correct-horse-9", confirmation: "correct-horse-9")
    }
}

/// A clock the test moves forward.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

extension AuthCoordinator {
    static func make(_ backend: FakeAuthBackend?, clock: TestClock = TestClock(),
                     invitations: PendingInvitationStore = PendingInvitationStore(keychain: nil),
                     phoneVerifications: PendingPhoneVerificationStore = PendingPhoneVerificationStore(keychain: nil)) -> AuthCoordinator {
        AuthCoordinator(backend: backend, invitations: invitations, defaults: nil, phoneVerifications: phoneVerifications, now: { clock.now })
    }
}
