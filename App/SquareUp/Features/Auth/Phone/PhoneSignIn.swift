import Foundation
import Observation
import OSLog

/// Phone numbers in the launch flow and in Profile → Sign-in methods (Firebase phone
/// authentication). Welcome's two choices stay; each opens its phone screen first, with "Use email
/// instead" switching in place, then a six-digit code. Square Up's own throttle sits on top of
/// Firebase's, a sent code survives leaving for Messages (or a relaunch), and nothing logs a number
/// or a code. Owned by `AuthCoordinator`, which finishes a sign-in exactly as for email.
@MainActor
@Observable
final class PhoneSignIn {
    /// How each entry screen collects the account (phone first when this build has it).
    private(set) var signUpMethod = AuthMethod.phone
    private(set) var signInMethod = AuthMethod.phone
    /// The number as typed, kept when switching to email and back or changing the number.
    var draft = PhoneDraft()
    /// The code sent and not yet entered.
    private(set) var verification: PendingPhoneVerification?
    private(set) var notice: PhoneNotice?
    /// What the next screen should explain (a new account from Sign in, an existing one from Create account).
    private(set) var outcome: PhoneOutcome?
    private(set) var isWorking = false
    private(set) var throttle: PhoneSendThrottle

    @ObservationIgnored weak var coordinator: AuthCoordinator?
    @ObservationIgnored private let backend: (any AuthBackend)?
    @ObservationIgnored private let store: PendingPhoneVerificationStore
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: () -> Date
    private static let throttleKey = "auth.phone-send-times"

    init(backend: (any AuthBackend)?, store: PendingPhoneVerificationStore, defaults: UserDefaults?, now: @escaping () -> Date) {
        self.backend = backend
        self.store = store
        self.defaults = defaults
        self.now = now
        throttle = defaults?.data(forKey: Self.throttleKey).flatMap { try? JSONDecoder().decode(PhoneSendThrottle.self, from: $0) } ?? PhoneSendThrottle()
    }

    /// Whether this build can verify phone numbers (Firebase's iOS app is configured).
    var isAvailable: Bool { backend?.isPhoneSignInAvailable ?? false }

    func method(for route: AuthRoute) -> AuthMethod {
        guard isAvailable else { return .email }
        return route == .signIn ? signInMethod : signUpMethod
    }

    /// "Use email instead" / "Use phone instead": in place, so Back still returns to Welcome.
    func use(_ method: AuthMethod, for route: AuthRoute) {
        guard method == .email || isAvailable else { return }
        notice = nil
        coordinator?.dismissNotice()
        if route == .signIn { signInMethod = method } else { signUpMethod = method }
    }

    /// When the next code may be sent (`nil`: now).
    var nextCodeAvailableAt: Date? { throttle.nextAllowed(at: now()) }

    /// Whole seconds until the next code may be sent (0: now), on the same clock as the throttle.
    var secondsUntilNextCode: Int {
        nextCodeAvailableAt.map { max(0, Int($0.timeIntervalSince(now()).rounded(.up))) } ?? 0
    }

    var isAtHourlyLimit: Bool { throttle.isAtHourlyLimit(at: now()) }

    // MARK: - Sending

    /// Sends a code to `phoneNumber` (E.164) and opens code entry. A code sent minutes ago to the
    /// same number for the same reason is reused instead of sending another.
    func sendCode(to phoneNumber: String, purpose: PhoneVerificationPurpose) async throws(AuthFailure) {
        guard let backend, !isWorking else { return }
        if let pending = verification ?? store.load(), pending.phoneNumber == phoneNumber, pending.purpose == purpose, pending.isFresh(at: now()) {
            verification = pending
            notice = .alreadySent
            showCodeEntry(for: purpose)
            return
        }
        if nextCodeAvailableAt != nil { throw .account(isAtHourlyLimit ? .tooManyAttempts : .codeCooldown) }
        isWorking = true
        defer { isWorking = false }
        let verificationID = try await backend.sendPhoneCode(to: phoneNumber)
        remember(PendingPhoneVerification(purpose: purpose, phoneNumber: phoneNumber, verificationID: verificationID, sentAt: now()))
        notice = .sent
        Log.app.info("Sent a phone verification code")
        showCodeEntry(for: purpose)
    }

    /// "Resend code", once the cooldown shown on screen has passed.
    func resend() async {
        guard let backend, let pending = verification, !isWorking, nextCodeAvailableAt == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let verificationID = try await backend.sendPhoneCode(to: pending.phoneNumber)
            remember(PendingPhoneVerification(purpose: pending.purpose, phoneNumber: pending.phoneNumber, verificationID: verificationID, sentAt: now()))
            notice = .resent
        } catch {
            notice = .problem(error)
            if error.isSessionEnded, pending.purpose == .link { await coordinator?.sessionEnded() }
        }
    }

    private func remember(_ pending: PendingPhoneVerification) {
        throttle.record(at: now())
        if let data = try? JSONEncoder().encode(throttle) { defaults?.set(data, forKey: Self.throttleKey) }
        verification = pending
        store.save(pending)
    }

    private func showCodeEntry(for purpose: PhoneVerificationPurpose) {
        guard purpose != .link, let coordinator, coordinator.path.last != .phoneCode else { return }
        coordinator.path.append(.phoneCode)
    }

    // MARK: - Verifying

    /// The six digits for Create account or Sign in. A known number signs in; a new number — from
    /// either path — goes on to choose a name, and the name step says why.
    func verify(code: String) async throws(AuthFailure) {
        guard let backend, let coordinator, let pending = verification, pending.purpose != .link, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        notice = nil
        let result = try await backend.signIn(phoneVerificationID: pending.verificationID, code: code)
        forgetVerification()
        outcome = switch (result.isNewUser, pending.purpose) {
        case (true, .signIn): .createdFromSignIn
        case (true, _): .created
        case (false, .signUp): .existingFromSignUp
        case (false, _): nil
        }
        Log.app.info("Signed in with a phone number")
        await coordinator.finishPhoneSignIn(result.details)
    }

    /// "Change number": back to the number as typed; the unused code is dropped.
    func changeNumber() {
        forgetVerification()
        notice = nil
        if coordinator?.path.last == .phoneCode { coordinator?.path.removeLast() }
    }

    func forgetVerification() {
        verification = nil
        store.clear()
    }

    /// After a relaunch, a code sent in the last few minutes returns to its code entry.
    func resumeIfAny() {
        guard isAvailable, let pending = store.load() else { return }
        guard pending.isFresh(at: now()) else {
            store.clear()
            return
        }
        guard pending.purpose != .link else { return }
        verification = pending
        let route: AuthRoute = pending.purpose == .signIn ? .signIn : .createAccount
        use(.phone, for: route)
        coordinator?.path = [route, .phoneCode]
    }

    /// Signing out (or a session ending): nothing about the last person's number stays.
    func reset() {
        forgetVerification()
        draft = PhoneDraft()
        notice = nil
        outcome = nil
        signUpMethod = .phone
        signInMethod = .phone
    }

    /// The new-account note has been shown on the name step.
    func clearOutcome() {
        outcome = nil
    }

    // MARK: - Adding a number to the signed-in account

    /// A code in progress for Profile → Sign-in methods (survives closing the sheet briefly).
    var pendingLink: PendingPhoneVerification? {
        guard let pending = verification ?? store.load(), pending.purpose == .link, pending.isFresh(at: now()) else { return nil }
        return pending
    }

    /// Links the verified number to this account — the same Firebase user, never a second account.
    /// A number that already belongs to another account is refused as such; accounts are never merged.
    func link(code: String) async throws(AuthFailure) {
        guard let backend, let coordinator, let pending = pendingLink, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        notice = nil
        do {
            let details = try await backend.linkPhone(verificationID: pending.verificationID, code: code)
            forgetVerification()
            coordinator.updateAccount(details)
            Log.app.info("Added a phone number to the account")
        } catch {
            if error == .account(.phoneInUse) { forgetVerification() }
            if error.isSessionEnded { await coordinator.sessionEnded() }
            throw error
        }
    }
}

/// The phone number field's contents: a country and what was typed.
nonisolated struct PhoneDraft: Equatable, Sendable {
    var regionCode: String?
    var text = ""
}

/// How an entry screen collects the account.
nonisolated enum AuthMethod: Equatable, Sendable {
    case phone
    case email
}

/// What happened with a phone number that the next screen should explain.
nonisolated enum PhoneOutcome: Equatable, Sendable {
    /// Create account with a new number.
    case created
    /// Sign in with a number that had no account: one was created, and it needs a name.
    case createdFromSignIn
    /// Create account with a number that already had an account: that account is signed in.
    case existingFromSignUp
}

/// A word on the code screen (or the Add phone number sheet).
nonisolated enum PhoneNotice: Equatable, Sendable {
    case sent
    case resent
    /// Continue again with the same number: the earlier code still works.
    case alreadySent
    case problem(AuthFailure)

    var message: String {
        switch self {
        case .sent: String(localized: "Code sent. It can take a minute to arrive.")
        case .resent: String(localized: "New code sent. Use the latest one.")
        case .alreadySent: String(localized: "We already sent a code to this number. Enter it below.")
        case .problem(let failure): failure.message
        }
    }

    var isProblem: Bool {
        if case .problem = self { true } else { false }
    }
}
