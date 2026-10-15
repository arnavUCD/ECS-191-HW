import Foundation

/// Where the launch flow is. One value decides what the app shows; nothing else routes.
nonisolated enum AuthPhase: Equatable, Sendable {
    /// Checking the session kept on this iPhone (the branded launch screen).
    case restoring
    /// No usable session: welcome, then sign in, create an account, or reset a password (`AuthRoute`).
    case signedOut
    /// Signed in, but Firebase hasn't confirmed the email address yet.
    case verifyingEmail
    /// Verified, but the name other people see hasn't been chosen.
    case needsProfile
    /// First run after choosing a name: optional payment methods, then a short welcome.
    case onboarding(OnboardingStep)
    /// Everything is in place: the app.
    case ready
    /// The session couldn't be checked and nothing on this iPhone is enough to continue (offline on
    /// a first launch, or the service failed). Retry, or sign out.
    case unavailable
}

nonisolated enum OnboardingStep: Equatable, Sendable {
    case paymentMethods
    case finished
}

/// Screens pushed over Welcome while signed out.
nonisolated enum AuthRoute: Hashable, Sendable {
    /// Phone first, with "Use email instead" switching the screen in place.
    case signIn
    case createAccount
    case resetPassword
    /// The six-digit code for the number entered on `signIn` or `createAccount`.
    case phoneCode
}

/// A short explanation shown on the current auth screen, with a symbol and words (never color alone).
nonisolated enum AuthNotice: Equatable, Sendable {
    /// The stored sign-in stopped working (expired, revoked, or the account changed elsewhere).
    case sessionEnded
    case signedOut
    case offline
    case serviceUnavailable
    /// The account exists but the verification email couldn't be sent yet.
    case verificationNotSent
    /// The verification email was sent (again).
    case verificationSent
    /// Firebase doesn't report the address as verified yet.
    case notVerifiedYet
    /// The demo workspace ended (a week passed, or it was deleted): Welcome offers a fresh one.
    case demoEnded
    /// "Leave demo": its fictional data was deleted.
    case leftDemo
    /// Any other failure, already in plain language.
    case problem(String)

    var message: String {
        switch self {
        case .sessionEnded: String(localized: "Your session ended. Sign in again to continue.")
        case .signedOut: String(localized: "You're signed out.")
        case .offline: String(localized: "You're offline. Connect to the internet and try again.")
        case .serviceUnavailable: String(localized: "Square Up couldn't reach its account service. Try again in a moment.")
        case .verificationNotSent: String(localized: "Your account is ready, but the email couldn't be sent yet. Tap Resend email.")
        case .verificationSent: String(localized: "Email sent. It can take a minute to arrive — check spam too.")
        case .notVerifiedYet: String(localized: "We haven't seen the confirmation yet. Open the link in the email, then try again.")
        case .demoEnded: String(localized: "That demo ended and its sample data was removed. Enter the demo again for a fresh copy.")
        case .leftDemo: String(localized: "You left the demo. Its sample data was removed from this iPhone and the server.")
        case .problem(let message): message
        }
    }

    var isProblem: Bool {
        switch self {
        case .verificationSent, .signedOut, .demoEnded, .leftDemo: false
        default: true
        }
    }
}

/// Inline validation for the account forms. Messages appear beside the field they describe.
nonisolated enum AuthValidation {
    static let maximumNameLength = 60

    static func nameIssue(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Enter the name people in your groups will see.") }
        if trimmed.count > maximumNameLength { return String(localized: "Use \(maximumNameLength) characters or fewer.") }
        return nil
    }

    static func emailIssue(_ email: String) -> String? {
        let trimmed = normalizedEmail(email)
        if trimmed.isEmpty { return String(localized: "Enter your email address.") }
        return isPlausibleEmail(trimmed) ? nil : String(localized: "Enter a valid email address, like name@example.com.")
    }

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One `@`, something before it, a dotted domain after it, and no spaces. Firebase has the final say.
    static func isPlausibleEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(where: \.isWhitespace) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    static func confirmationIssue(password: String, confirmation: String) -> String? {
        confirmation.isEmpty || confirmation == password ? nil : String(localized: "The passwords don't match.")
    }
}

/// The password rules shown during sign-up: Firebase's project policy when it enforces one,
/// never below Square Up's own minimum of 8 characters (Firebase's built-in floor is 6).
nonisolated struct PasswordRules: Equatable, Sendable {
    static let squareUpMinimum = 8

    var minimumLength = PasswordRules.squareUpMinimum
    var maximumLength: Int?
    var requiresLowercase = false
    var requiresUppercase = false
    var requiresNumber = false
    var requiresSymbol = false

    init() {}

    init(policy: AccountSession.PasswordPolicy?) {
        guard let policy else { return }
        minimumLength = max(Self.squareUpMinimum, policy.minimumLength)
        maximumLength = policy.maximumLength
        requiresLowercase = policy.requiresLowercase
        requiresUppercase = policy.requiresUppercase
        requiresNumber = policy.requiresNumber
        requiresSymbol = policy.requiresSymbol
    }

    nonisolated struct Requirement: Equatable, Sendable, Identifiable {
        let id: String
        let text: String
        let isMet: Bool
    }

    func requirements(for password: String) -> [Requirement] {
        var list = [Requirement(id: "length", text: String(localized: "At least \(minimumLength) characters"), isMet: password.count >= minimumLength)]
        if let maximumLength, password.count > maximumLength {
            list.append(Requirement(id: "maximum", text: String(localized: "No more than \(maximumLength) characters"), isMet: false))
        }
        if requiresLowercase {
            list.append(Requirement(id: "lower", text: String(localized: "A lowercase letter"), isMet: password.contains(where: \.isLowercase)))
        }
        if requiresUppercase {
            list.append(Requirement(id: "upper", text: String(localized: "An uppercase letter"), isMet: password.contains(where: \.isUppercase)))
        }
        if requiresNumber {
            list.append(Requirement(id: "number", text: String(localized: "A number"), isMet: password.contains(where: \.isNumber)))
        }
        if requiresSymbol {
            list.append(Requirement(id: "symbol", text: String(localized: "A symbol, like ! or #"),
                                    isMet: password.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }))
        }
        return list
    }

    func accepts(_ password: String) -> Bool { requirements(for: password).allSatisfy(\.isMet) }
}

/// The create-account form, validated before anything is sent.
nonisolated struct SignUpForm: Equatable, Sendable {
    nonisolated enum Field: Hashable, Sendable { case name, email, password, confirmation }

    var name = ""
    var email = ""
    var password = ""
    var confirmation = ""

    func issues(rules: PasswordRules) -> [Field: String] {
        var issues: [Field: String] = [:]
        if let issue = AuthValidation.nameIssue(name) { issues[.name] = issue }
        if let issue = AuthValidation.emailIssue(email) { issues[.email] = issue }
        if !rules.accepts(password) { issues[.password] = String(localized: "Choose a password that meets every requirement below.") }
        if confirmation.isEmpty {
            issues[.confirmation] = String(localized: "Enter the password again.")
        } else if let issue = AuthValidation.confirmationIssue(password: password, confirmation: confirmation) {
            issues[.confirmation] = issue
        }
        return issues
    }
}

/// Every full account needs an identity Firebase reports as verified — an email address it
/// confirmed, or a phone number verified with a code — no exceptions, whenever it was created.
/// The server enforces the same rule on every protected endpoint.
nonisolated enum VerificationPolicy {
    static func requiresVerification(_ details: AccountSession.AccountDetails) -> Bool {
        !details.isDemo && !details.emailVerified && details.phoneNumber == nil
    }

    /// Offline launch: decides from what this iPhone remembers. An unknown state (an account
    /// remembered by an earlier build) isn't trusted; it's checked again when online. A phone
    /// number is only ever stored after Firebase verified it.
    static func requiresVerification(_ stored: AccountSession.StoredAccount) -> Bool {
        !stored.isDemo && stored.emailVerified != true && stored.phoneNumber == nil
    }
}
