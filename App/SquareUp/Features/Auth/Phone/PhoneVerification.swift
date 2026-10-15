import Foundation

/// Why a phone number is being verified.
nonisolated enum PhoneVerificationPurpose: String, Codable, Sendable {
    /// Welcome → Create account.
    case signUp
    /// Welcome → Sign in.
    case signIn
    /// Profile → Sign-in methods → Add phone number (the signed-in account keeps its UID).
    case link
}

/// A code Firebase sent and the person hasn't entered yet. Kept in the Keychain (this iPhone only)
/// so leaving for Messages — even if iOS closes Square Up meanwhile — returns to code entry. The
/// code itself is never stored.
nonisolated struct PendingPhoneVerification: Codable, Equatable, Sendable {
    let purpose: PhoneVerificationPurpose
    /// E.164.
    let phoneNumber: String
    /// Firebase's verification ID (`sessionInfo`), not a secret on its own but never logged.
    let verificationID: String
    let sentAt: Date

    /// How long a sent code is offered for resuming. Firebase decides when it really expires; an
    /// older one fails with "expired" and can be sent again.
    static let resumeWindow: TimeInterval = 15 * 60

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(sentAt) < Self.resumeWindow }
}

/// Persists the code in progress. `nil` keychain (tests, UI tests): kept in memory only.
@MainActor
final class PendingPhoneVerificationStore {
    private let keychain: KeychainStore?
    private var memory: PendingPhoneVerification?
    private static let key = "auth.pending-phone-verification"

    init(keychain: KeychainStore?) {
        self.keychain = keychain
    }

    func load() -> PendingPhoneVerification? {
        guard let keychain else { return memory }
        return keychain.data(for: Self.key).flatMap { try? JSONDecoder().decode(PendingPhoneVerification.self, from: $0) }
    }

    func save(_ pending: PendingPhoneVerification) {
        memory = pending
        if let keychain, let data = try? JSONEncoder().encode(pending) { keychain.set(data, for: Self.key) }
    }

    func clear() {
        memory = nil
        keychain?.remove(Self.key)
    }
}

/// Square Up's own brake on sending codes, on top of Firebase's: one send at a time, at least a
/// minute apart, and at most five in an hour on this iPhone. Only times are kept — never numbers.
nonisolated struct PhoneSendThrottle: Codable, Equatable, Sendable {
    static let cooldown: TimeInterval = 60
    static let window: TimeInterval = 60 * 60
    static let maximumInWindow = 5

    private(set) var sends: [Date] = []

    /// When the next code may be sent; `nil` means now.
    func nextAllowed(at now: Date) -> Date? {
        let recent = sends.filter { now.timeIntervalSince($0) < Self.window }.sorted()
        var earliest: Date?
        if let last = recent.last, now.timeIntervalSince(last) < Self.cooldown {
            earliest = last.addingTimeInterval(Self.cooldown)
        }
        if recent.count >= Self.maximumInWindow, let oldest = recent.first {
            let reopens = oldest.addingTimeInterval(Self.window)
            earliest = max(earliest ?? reopens, reopens)
        }
        return earliest
    }

    /// Whether the hourly limit (not just the short cooldown) is what's waiting.
    func isAtHourlyLimit(at now: Date) -> Bool {
        sends.filter { now.timeIntervalSince($0) < Self.window }.count >= Self.maximumInWindow
    }

    mutating func record(at now: Date) {
        sends = sends.filter { now.timeIntervalSince($0) < Self.window } + [now]
    }
}

/// A Firebase sign-in completed by the phone verifier, handed to `AccountSession` so phone and
/// email accounts end up in the same session (refresh token in the Keychain, ID tokens in memory).
nonisolated struct PhoneCredentialSession: Equatable, Sendable {
    let userID: String
    let idToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    /// E.164, as Firebase verified it.
    let phoneNumber: String
    /// Firebase created this account just now.
    let isNewUser: Bool
}

/// Sends verification codes and signs in with them — Firebase's Apple-platform phone
/// authentication (`FirebasePhoneVerifier`) in the app, a stand-in in tests. No SMS ever goes
/// through Square Up's server.
@MainActor
protocol PhoneVerifying: AnyObject {
    /// Sends a code to an E.164 number; returns Firebase's verification ID. May show Firebase's
    /// reCAPTCHA check when silent push verification isn't available.
    func sendCode(to phoneNumber: String) async throws(AccountSession.Failure) -> String
    /// Signs in to (or creates) the number's Firebase account with the entered code.
    func signIn(verificationID: String, code: String) async throws(AccountSession.Failure) -> PhoneCredentialSession
}
