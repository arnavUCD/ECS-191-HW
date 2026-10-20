import Foundation
import Observation
import OSLog

/// The launch and account flow (sign-in, sign-up, email verification, first-run setup) as one
/// state machine. `phase` alone decides what the app shows, so the main app can never appear
/// before the session is resolved.
///
/// - Without a backend (a build with no Firebase configured, previews, and the historical UI
///   tests) the flow is skipped and the app opens as before.
/// - Every request runs one at a time (`isWorking`), so double taps can't submit twice; results
///   that arrive after the person moved on are ignored.
/// - Offline doesn't sign anyone out: a verified account with a profile on this iPhone opens the
///   app with its saved data. Only a refused refresh token ends the session.
/// - Nothing personal (email, name, codes, tokens) is logged.
@MainActor
@Observable
final class AuthCoordinator {
    private(set) var phase: AuthPhase
    /// Screens pushed over Welcome while signed out.
    var path: [AuthRoute] = []
    private(set) var notice: AuthNotice?
    /// The signed-in account as Firebase last reported it.
    private(set) var details: AccountSession.AccountDetails?
    private(set) var profile: AuthProfile?
    private(set) var rules = PasswordRules()
    private(set) var isWorking = false
    private(set) var isCheckingVerification = false
    private(set) var verificationResendAvailableAt: Date?
    private(set) var resetResendAvailableAt: Date?
    /// The address a reset link was last requested for (shown on the confirmation).
    private(set) var resetSentTo: String?
    private(set) var pendingInvitation: PendingInvitation?
    /// Prefills sign-in after a session ended, and sign-up after "Use a different email".
    private(set) var rememberedEmail: String?
    /// Prefills the name step: what the person typed at sign-up, or the name on the account.
    private(set) var draftName = ""
    /// A new address waiting for its link to be opened (the account keeps its old one until then).
    private(set) var pendingEmail: String?
    /// Firebase asked for a fresh sign-in before an email change or deletion.
    private(set) var needsRecentSignIn = false
    /// Phone numbers: entry, codes, and adding a number in Profile.
    @ObservationIgnored let phone: PhoneSignIn

    /// Hands an invitation to the app once it's ready (set by the app).
    @ObservationIgnored var deliverInvitation: (PendingInvitation) -> Void = { _ in }
    @ObservationIgnored private let backend: (any AuthBackend)?
    @ObservationIgnored private let invitations: PendingInvitationStore
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastAutomaticCheck: Date?
    @ObservationIgnored private var loadedRules = false

    static let resendCooldown: TimeInterval = 60
    /// Foreground checks of the verification status are at most this frequent.
    static let automaticCheckInterval: TimeInterval = 5
    private static let resendKey = "auth.verification-resend-available-at"

    init(backend: (any AuthBackend)?, invitations: PendingInvitationStore, defaults: UserDefaults? = nil,
         phoneVerifications: PendingPhoneVerificationStore = PendingPhoneVerificationStore(keychain: nil), now: @escaping () -> Date = { .now }) {
        self.backend = backend
        self.invitations = invitations
        self.defaults = defaults
        self.now = now
        phone = PhoneSignIn(backend: backend, store: phoneVerifications, defaults: defaults, now: now)
        phase = backend == nil ? .ready : .restoring
        pendingInvitation = backend == nil ? nil : invitations.load()
        verificationResendAvailableAt = defaults?.object(forKey: Self.resendKey) as? Date
        phone.coordinator = self
    }

    /// Whether this build requires an account before the app opens.
    var isGated: Bool { backend != nil }
    var email: String? { details?.email ?? rememberedEmail }
    var isEmailVerified: Bool { details?.emailVerified ?? false }
    /// How the account is shown to its owner: the email, or the phone number.
    var accountLabel: String? { email ?? details?.phoneNumber.map { PhoneNumbers.shared.display($0) } }
    var unsentChangeCount: Int { backend?.unsentChangeCount ?? 0 }
    /// Demo Mode: the open account is a demo workspace of fictional sample data.
    var isDemo: Bool { details?.isDemo ?? false }
    /// Whether Welcome offers "Enter Demo".
    var isDemoAvailable: Bool { backend?.isDemoAvailable ?? false }
    /// "Enter Demo" is setting up the workspace (Welcome shows its progress).
    private(set) var isEnteringDemo = false

    // MARK: - Launch

    /// Restores the session kept on this iPhone and decides where to go.
    func start() async {
        guard let backend, phase == .restoring else { return }
        guard let stored = await backend.storedAccount(), !stored.isAnonymous else {
            // A fresh install, or an older anonymous account (kept so creating an account upgrades it).
            phase = .signedOut
            phone.resumeIfAny() // a code sent before iOS closed the app
            return
        }
        rememberedEmail = stored.email
        if stored.isDemo {
            // Offline launches open the demo's saved copy, like any account's.
            details = AccountSession.AccountDetails(userID: stored.userID, email: nil, emailVerified: false, displayName: nil,
                                                    createdAt: stored.createdAt, isDemo: true)
        }
        do {
            await route(try backend.restore())
        } catch {
            await restoreFailed(error, stored: stored)
        }
    }

    /// From `unavailable`: check again.
    func retry() async {
        guard phase == .unavailable || phase == .restoring else { return }
        notice = nil
        if details == nil {
            phase = .restoring
            await start()
        } else {
            await continueWithProfile()
        }
    }

    private func restoreFailed(_ error: AuthFailure, stored: AccountSession.StoredAccount) async {
        if error.isSessionEnded {
            await endSession()
            return
        }
        // Offline or the service failed: continue with what this iPhone remembers.
        let reason: AuthNotice = error.isOffline ? .offline : .serviceUnavailable
        if VerificationPolicy.requiresVerification(stored) {
            details = AccountSession.AccountDetails(userID: stored.userID, email: stored.email, emailVerified: false, displayName: nil,
                                                    createdAt: stored.createdAt, phoneNumber: stored.phoneNumber)
            notice = reason
            phase = .verifyingEmail
            return
        }
        if stored.hasProfile != false, let cached = await backend?.cachedProfile() {
            Log.app.info("Opened with the account's saved data while the account service was unreachable")
            await enter(cached, firstRun: false)
            return
        }
        notice = reason
        phase = .unavailable
    }

    private func route(_ details: AccountSession.AccountDetails) async {
        self.details = details
        rememberedEmail = details.email
        if draftName.isEmpty, let name = details.displayName { draftName = name }
        if VerificationPolicy.requiresVerification(details) {
            phase = .verifyingEmail
        } else {
            await continueWithProfile()
        }
    }

    private func continueWithProfile() async {
        guard let backend else { return }
        do {
            if let profile = try await backend.loadProfile() {
                await enter(profile, firstRun: false)
            } else {
                notice = nil
                phase = .needsProfile
            }
        } catch {
            if error.isSessionEnded {
                await endSession()
            } else if let cached = await backend.cachedProfile() {
                await enter(cached, firstRun: false)
            } else {
                notice = error.isOffline ? .offline : .serviceUnavailable
                phase = .unavailable
            }
        }
    }

    private func enter(_ profile: AuthProfile, firstRun: Bool) async {
        self.profile = profile
        await backend?.prepareApp(for: profile)
        if firstRun {
            phase = .onboarding(.paymentMethods)
        } else {
            openApp()
        }
    }

    private func openApp() {
        notice = nil
        path = []
        phase = .ready
        deliverPendingInvitation()
    }

    /// A phone sign-in finished (`PhoneSignIn.verify`): on exactly like an email sign-in.
    func finishPhoneSignIn(_ details: AccountSession.AccountDetails) async {
        path = []
        notice = nil
        await route(details)
    }

    /// The account changed while signed in (a phone number was added).
    func updateAccount(_ details: AccountSession.AccountDetails) {
        self.details = details
    }

    // MARK: - Signed out

    func show(_ route: AuthRoute) {
        notice = nil
        if route == .createAccount || route == .signIn {
            path = [route]
        } else {
            path.append(route)
        }
    }

    /// "Forgot password?": the address typed on sign-in carries over.
    func showPasswordReset(email: String) {
        let address = AuthValidation.normalizedEmail(email)
        if !address.isEmpty { rememberedEmail = address }
        show(.resetPassword)
    }

    /// Firebase's password policy for this project, read once when sign-up opens.
    func loadPasswordRules() async {
        guard !loadedRules, let backend else { return }
        loadedRules = true
        rules = await PasswordRules(policy: backend.passwordPolicy())
    }

    func signUp(_ form: SignUpForm) async throws(AuthFailure) {
        guard let backend, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let email = AuthValidation.normalizedEmail(form.email)
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = try await backend.signUp(email: email, password: form.password, displayName: name)
        draftName = name
        self.details = details
        rememberedEmail = email
        do {
            try await backend.sendVerificationEmail()
            startVerificationCooldown()
            notice = nil
        } catch {
            notice = .verificationNotSent
        }
        path = []
        Log.app.info("Created an account; waiting for email verification")
        if VerificationPolicy.requiresVerification(details) {
            phase = .verifyingEmail
        } else {
            await continueWithProfile()
        }
    }

    func signIn(email: String, password: String) async throws(AuthFailure) {
        guard let backend, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let details = try await backend.signIn(email: AuthValidation.normalizedEmail(email), password: password)
        path = []
        notice = nil
        await route(details)
    }

    var canResendPasswordReset: Bool { resetResendAvailableAt.map { now() >= $0 } ?? true }

    func sendPasswordReset(email: String) async throws(AuthFailure) {
        guard let backend, !isWorking, canResendPasswordReset else { return }
        isWorking = true
        defer { isWorking = false }
        let address = AuthValidation.normalizedEmail(email)
        try await backend.sendPasswordReset(email: address)
        resetSentTo = address
        resetResendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
    }

    /// Back to the reset form (to correct the address).
    func editPasswordResetEmail() {
        resetSentTo = nil
    }

    // MARK: - Profile and first run

    func saveProfile(displayName: String) async throws(AuthFailure) {
        guard let backend, phase == .needsProfile, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = name
        let profile = try await backend.saveProfile(displayName: name)
        Log.app.info("Saved the profile name")
        await enter(profile, firstRun: true)
    }

    /// Payment methods are optional: "Set up later" and "Continue" both move on.
    func finishPaymentStep() {
        guard phase == .onboarding(.paymentMethods) else { return }
        phase = .onboarding(.finished)
    }

    func finishOnboarding() {
        guard phase == .onboarding(.finished) else { return }
        openApp()
    }

    // MARK: - Signing out and ended sessions

    /// Profile → Sign out: back to Welcome. Shared groups stay on the server.
    func signOut() async {
        guard isGated else { return }
        await backend?.signOut()
        clearAccount()
        // On a shared iPhone the next person shouldn't see who signed in before them.
        rememberedEmail = nil
        pendingEmail = nil
        draftName = ""
        phone.reset()
        clearVerificationCooldown()
        clearPendingInvitation()
        path = []
        notice = .signedOut
        phase = .signedOut
    }

    /// The session ended while the app was open (the server or Firebase refused the sign-in).
    func sessionEnded() async {
        guard isGated, phase == .ready else { return }
        await endSession()
    }

    private func endSession() async {
        if isDemo {
            // A demo ends after a week (or was deleted): back to Welcome, where a fresh one is a tap away.
            Log.app.info("The demo workspace ended; returning to Welcome")
            await backend?.signOut()
            clearAccount()
            path = []
            notice = .demoEnded
            phase = .signedOut
            return
        }
        Log.app.info("The stored sign-in no longer works; returning to sign in")
        let email = email
        let phoneNumber = details?.phoneNumber
        await backend?.signOut()
        clearAccount()
        rememberedEmail = email
        // Sign in again the way this account did: its email, or its number.
        phone.reset()
        if email != nil, phoneNumber == nil { phone.use(.email, for: .signIn) }
        if let phoneNumber { phone.draft = PhoneDraft(text: PhoneNumbers.shared.display(phoneNumber)) }
        path = [.signIn]
        notice = .sessionEnded
        phase = .signedOut
    }

    private func clearAccount() {
        details = nil
        profile = nil
        lastAutomaticCheck = nil
    }

    // MARK: - Demo Mode

    /// "Enter Demo" on Welcome: the server creates this iPhone's own workspace of fictional sample
    /// data, and the app opens on it exactly as it does for a signed-in account.
    func enterDemo() async {
        guard let backend, phase == .signedOut, !isWorking else { return }
        isWorking = true
        isEnteringDemo = true
        defer {
            isWorking = false
            isEnteringDemo = false
        }
        notice = nil
        do {
            let details = try await backend.enterDemo()
            path = []
            phone.reset()
            await route(details)
        } catch {
            notice = error.isOffline ? .offline : .problem(error.message)
        }
    }

    /// Profile → Reset demo data: this workspace (and only it) goes back to its seed.
    func resetDemo() async throws(AuthFailure) {
        guard let backend, isDemo, phase == .ready, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            profile = try await backend.resetDemo()
        } catch {
            if error.isSessionEnded { await endSession() }
            throw error
        }
    }

    /// Profile → Leave demo: its sample data is deleted, and Welcome comes back.
    func leaveDemo() async {
        guard let backend, isDemo else { return }
        await backend.leaveDemo()
        clearAccount()
        path = []
        notice = .leftDemo
        phase = .signedOut
    }

    // MARK: - Deleting the account

    /// Profile → Delete account: what deleting would do now, and anything to finish first.
    func accountDeletionPlan() async throws(AuthFailure) -> AccountDeletionPlan {
        guard let backend, phase == .ready, !isDemo else { throw .account(.signedOut) }
        do {
            return try await backend.accountDeletionPlan()
        } catch {
            if error.isSessionEnded { await endSession() }
            throw error
        }
    }

    /// Sends a code to the account's own number, to confirm it's this person before deleting.
    func sendDeletionCode() async throws(AuthFailure) -> String {
        guard let backend, phase == .ready, !isDemo else { throw .account(.signedOut) }
        return try await backend.sendReauthenticationCode()
    }

    /// Confirms it's this person (their password, or the code texted to their number), then deletes
    /// the account: its data on the server, its sign-in, and everything this iPhone kept for it.
    /// Back to Welcome afterwards. Nothing is deleted if the confirmation fails.
    func deleteAccount(_ confirmation: AccountConfirmation) async throws(AuthFailure) {
        guard let backend, phase == .ready, !isDemo, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        switch confirmation {
        case .password(let password): try await backend.reauthenticate(password: password)
        case .code(let verificationID, let code): try await backend.reauthenticate(phoneVerificationID: verificationID, code: code)
        }
        let outcome = try await backend.deleteAccount()
        Log.app.info("Account deleted; returning to Welcome")
        clearAccount()
        rememberedEmail = nil
        pendingEmail = nil
        draftName = ""
        phone.reset()
        clearVerificationCooldown()
        clearPendingInvitation()
        path = []
        notice = outcome == .complete ? .accountDeleted : .accountDeletedLocalDataRemains
        phase = .signedOut
    }

    // MARK: - Invitations

    /// An invitation opened from a link. Before the app is ready it waits (on this iPhone, across
    /// relaunches) until sign-in and setup are done; then it opens automatically.
    func receive(_ invitation: PendingInvitation) {
        guard phase != .ready else {
            deliverInvitation(invitation)
            return
        }
        pendingInvitation = invitation
        invitations.save(invitation)
    }

    private func deliverPendingInvitation() {
        guard let pending = pendingInvitation ?? invitations.load() else { return }
        clearPendingInvitation()
        deliverInvitation(pending)
    }

    private func clearPendingInvitation() {
        pendingInvitation = nil
        invitations.clear()
    }
}

// MARK: - Email verification

extension AuthCoordinator {
    var canResendVerification: Bool { verificationResendAvailableAt.map { now() >= $0 } ?? true }

    /// Verification happens only at the "Check your email" step; the app never opens unverified.
    private var canVerify: Bool { phase == .verifyingEmail }

    /// Asks Firebase whether the address is verified. Automatic checks (returning to the app) are
    /// quiet and throttled; a tap explains what happened. A verified address also gets a fresh ID
    /// token (in the backend) so the server sees `email_verified` straight away.
    func checkVerification(userInitiated: Bool) async {
        guard let backend, canVerify, !isCheckingVerification else { return }
        if !userInitiated {
            if let last = lastAutomaticCheck, now().timeIntervalSince(last) < Self.automaticCheckInterval { return }
            lastAutomaticCheck = now()
        }
        let startedIn = phase
        isCheckingVerification = true
        defer { isCheckingVerification = false }
        do {
            let details = try await backend.reload()
            guard phase == startedIn else { return }
            self.details = details
            rememberedEmail = details.email
            if let pending = pendingEmail, details.email?.lowercased() == pending.lowercased() { pendingEmail = nil }
            if VerificationPolicy.requiresVerification(details) {
                if userInitiated { notice = .notVerifiedYet }
            } else {
                Log.app.info("Email verified")
                clearVerificationCooldown()
                notice = nil
                await continueWithProfile()
            }
        } catch {
            guard phase == startedIn else { return }
            if error.isSessionEnded {
                await endSession()
            } else if userInitiated {
                notice = error.isOffline ? .offline : .serviceUnavailable
            }
        }
    }

    /// Sends (or re-sends) the verification email, waiting out the cooldown.
    func resendVerification() async {
        guard let backend, canVerify, !isWorking, canResendVerification else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.sendVerificationEmail()
            startVerificationCooldown()
            notice = .verificationSent
        } catch {
            if error == .account(.tooManyAttempts) { startVerificationCooldown() }
            if error.isSessionEnded {
                await endSession()
            } else {
                notice = error.isOffline ? .offline : .problem(error.message)
            }
        }
    }

    /// "Use a different email" for an unverified sign-up: Firebase sends a link to the new address and
    /// changes the account's email (verified) only when it's opened. Nothing is deleted, and a failure
    /// leaves the account exactly as it was.
    func changeEmail(to newEmail: String) async throws(AuthFailure) {
        guard let backend, phase == .verifyingEmail, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let address = AuthValidation.normalizedEmail(newEmail)
        do {
            try await backend.requestEmailChange(to: address)
        } catch {
            if error == .account(.recentSignInRequired) { needsRecentSignIn = true }
            if error.isSessionEnded { await endSession() }
            throw error
        }
        pendingEmail = address
        needsRecentSignIn = false
        startVerificationCooldown()
        notice = .verificationSent
        Log.app.info("Requested an email change for an unverified account")
    }

    /// Deletes the current sign-up and starts again — only an incomplete one: unverified and without
    /// a profile. Established accounts (verified, or with a profile) are never deleted here. A
    /// network failure keeps the account and its state; a lost response is safe to retry.
    func deleteAndStartOver() async throws(AuthFailure) {
        guard let backend, phase == .verifyingEmail, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        guard details?.emailVerified != true else {
            throw .server(String(localized: "This account is verified, so it can't be deleted here."))
        }
        guard try await backend.loadProfile() == nil else {
            throw .server(String(localized: "This account is already set up, so it can't be deleted here."))
        }
        do {
            try await backend.deleteIncompleteAccount()
        } catch {
            if error == .account(.recentSignInRequired) { needsRecentSignIn = true }
            throw error
        }
        Log.app.info("Deleted an incomplete sign-up")
        clearAccount()
        rememberedEmail = nil
        pendingEmail = nil
        needsRecentSignIn = false
        clearVerificationCooldown()
        phone.use(.email, for: .createAccount) // back to the email form they were using
        path = [.createAccount]
        notice = nil
        phase = .signedOut
    }

    /// Firebase wants a fresh sign-in before a sensitive change: sign in again, then retry.
    func signInAgain() async {
        let email = email
        await backend?.signOut()
        clearAccount()
        pendingEmail = nil
        needsRecentSignIn = false
        rememberedEmail = email
        phone.use(.email, for: .signIn)
        path = [.signIn]
        notice = .problem(LedgerErrorMessages.text(for: AccountSession.Failure.recentSignInRequired))
        phase = .signedOut
    }

    func dismissNotice() {
        notice = nil
    }

    func startVerificationCooldown() {
        let date = now().addingTimeInterval(Self.resendCooldown)
        verificationResendAvailableAt = date
        defaults?.set(date, forKey: Self.resendKey)
    }

    func clearVerificationCooldown() {
        verificationResendAvailableAt = nil
        defaults?.removeObject(forKey: Self.resendKey)
    }
}
