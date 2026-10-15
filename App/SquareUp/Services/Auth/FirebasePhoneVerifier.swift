import FirebaseAuth
import FirebaseCore
import Foundation
import OSLog
import UIKit

/// Firebase's Apple-platform phone authentication — the one place Square Up uses the Firebase
/// SDK. It sends the SMS (`PhoneAuthProvider.verifyPhoneNumber`, with silent push or the reCAPTCHA
/// fallback for app verification) and signs in with the code. The resulting session is handed to
/// `AccountSession` and the SDK's own copy is signed out straight away, so there is exactly one
/// session — the same one email accounts use — and sign-out, token refresh, account switching, and
/// relaunch behave the same for everyone.
///
/// Configured only when the build carries a registered Firebase iOS app (Google App ID, sender ID,
/// project, and the matching reCAPTCHA URL scheme in Info.plist — see `PHONE_AUTH_SETUP.md`).
/// Without all of them it's `nil` and the app offers email only: Firebase would otherwise crash on
/// a missing URL scheme. Nothing here logs a phone number, code, verification ID, or token.
@MainActor
final class FirebasePhoneVerifier: PhoneVerifying {
    /// The verifier for this launch, configured once from Info.plist (`nil` when not set up).
    static let shared: FirebasePhoneVerifier? = FirebasePhoneVerifier(info: Bundle.main.infoDictionary ?? [:], configuration: .current)

    private let settings: Settings
    private let usesTestNumbers: Bool

    /// Firebase starts on first use, never when `shared` is created: `shared` is first read in
    /// `SquareUpApp.init`, before UIKit creates the `UIApplication`, and an `Auth` started then has
    /// no notification manager — every `verifyPhoneNumber` fails with `notificationNotForwarded`
    /// (17054). `SquareUpAppDelegate` calls `start()` once the application exists.
    private lazy var auth: Auth = {
        FirebaseApp.configure(options: Self.options(settings))
        let auth = Auth.auth()
        auth.useAppLanguage()
        #if DEBUG
        // Simulator testing with Firebase's fictional numbers only (`-SUPhoneAuthTestNumbers`).
        // Release builds can't reach this line.
        if usesTestNumbers { auth.settings?.isAppVerificationDisabledForTesting = true }
        #endif
        return auth
    }()

    private init?(info: [String: Any], configuration: LaunchConfiguration) {
        guard let settings = Self.settings(from: info), Self.registersCallbackScheme(for: settings.googleAppID, info: info) else { return nil }
        self.settings = settings
        usesTestNumbers = configuration.usesPhoneAuthTestNumbers
    }

    /// Configures Firebase; called from `application(_:didFinishLaunchingWithOptions:)`.
    func start() {
        _ = auth
    }

    /// The registered Firebase iOS app, from the build settings (`Config/Remote.xcconfig`, public
    /// client identifiers; optionally overridden by `Remote.local.xcconfig`): every value set, none
    /// left as an unexpanded `$(…)`.
    nonisolated struct Settings: Equatable, Sendable {
        let googleAppID: String
        let gcmSenderID: String
        let projectID: String
        let apiKey: String
    }

    nonisolated static func settings(from info: [String: Any]) -> Settings? {
        func value(_ key: String) -> String? {
            guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
            return raw
        }
        guard let appID = value("SquareUpFirebaseGoogleAppID"), let sender = value("SquareUpFirebaseGCMSenderID"),
              let project = value("SquareUpFirebaseProjectID"),
              let apiKey = value("SquareUpFirebaseIOSAPIKey") ?? value("SquareUpFirebaseAPIKey") else { return nil }
        return Settings(googleAppID: appID, gcmSenderID: sender, projectID: project, apiKey: apiKey)
    }

    private static func options(_ settings: Settings) -> FirebaseOptions {
        let options = FirebaseOptions(googleAppID: settings.googleAppID, gcmSenderID: settings.gcmSenderID)
        options.apiKey = settings.apiKey
        options.projectID = settings.projectID
        options.bundleID = Bundle.main.bundleIdentifier ?? ""
        return options
    }

    /// Firebase returns from reCAPTCHA through `app-<encoded Google App ID>`; verifying a number
    /// without that scheme registered stops the app, so phone sign-in stays off until it is.
    nonisolated static func callbackScheme(forGoogleAppID appID: String) -> String {
        "app-" + appID.replacingOccurrences(of: ":", with: "-")
    }

    nonisolated static func registersCallbackScheme(for appID: String, info: [String: Any]) -> Bool {
        let wanted = callbackScheme(forGoogleAppID: appID).lowercased()
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains { $0.lowercased() == wanted } }
    }

    // MARK: - PhoneVerifying

    func sendCode(to phoneNumber: String) async throws(AccountSession.Failure) -> String {
        do {
            return try await PhoneAuthProvider.provider(auth: auth).verifyPhoneNumber(phoneNumber, uiDelegate: nil, multiFactorSession: nil)
        } catch {
            throw Self.failure(error)
        }
    }

    func signIn(verificationID: String, code: String) async throws(AccountSession.Failure) -> PhoneCredentialSession {
        let credential = PhoneAuthProvider.provider(auth: auth).credential(withVerificationID: verificationID, verificationCode: code)
        do {
            let result = try await auth.signIn(with: credential)
            defer { try? auth.signOut() } // the session now lives in AccountSession only
            let token = try await result.user.getIDTokenResult(forcingRefresh: false)
            guard let refreshToken = result.user.refreshToken, let phoneNumber = result.user.phoneNumber else { throw AccountSession.Failure.unavailable }
            return PhoneCredentialSession(
                userID: result.user.uid, idToken: token.token, refreshToken: refreshToken,
                expiresIn: max(60, token.expirationDate.timeIntervalSinceNow), phoneNumber: phoneNumber,
                isNewUser: result.additionalUserInfo?.isNewUser ?? false
            )
        } catch let failure as AccountSession.Failure {
            try? auth.signOut()
            throw failure
        } catch {
            try? auth.signOut()
            throw Self.failure(error)
        }
    }

    // MARK: - App delegate and URLs

    /// APNs device token for silent-push app verification (`SquareUpAppDelegate`).
    func setAPNSToken(_ token: Data) {
        auth.setAPNSToken(token, type: .unknown)
    }

    /// Firebase's silent verification notification, if this is one.
    func canHandleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        auth.canHandleNotification(userInfo)
    }

    /// The reCAPTCHA redirect (`app-…://`), never Square Up's own `squp://` or invitation links.
    func canHandle(_ url: URL) -> Bool {
        Self.isFirebaseRedirect(url) && auth.canHandle(url)
    }

    nonisolated static func isFirebaseRedirect(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme.hasPrefix("app-") || scheme.hasPrefix("com.googleusercontent.apps.")
    }

    // MARK: - Errors

    /// Firebase's error in Square Up's terms. Never says whether a number has an account.
    static func failure(_ error: any Error) -> AccountSession.Failure {
        let nsError = error as NSError
        guard nsError.domain == AuthErrors.domain, let code = AuthErrorCode(rawValue: nsError.code) else {
            return TransportFailure.isOffline(error) ? .offline : .unavailable
        }
        Log.app.error("Phone verification failed: \(code.rawValue, privacy: .public)")
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber: return .invalidPhoneNumber
        case .invalidVerificationCode, .missingVerificationCode: return .invalidCode
        case .sessionExpired, .invalidVerificationID: return .codeExpired
        case .tooManyRequests: return .tooManyAttempts
        case .quotaExceeded: return .smsQuotaExceeded
        case .networkError, .webNetworkRequestFailed: return .offline
        case .webContextCancelled: return .verificationCancelled
        case .credentialAlreadyInUse, .accountExistsWithDifferentCredential: return .phoneInUse
        case .userDisabled: return .accountDisabled
        case .operationNotAllowed: return .phoneNotAllowed
        case .captchaCheckFailed, .appNotVerified, .missingAppToken, .notificationNotForwarded, .invalidAppCredential,
             .missingAppCredential, .appNotAuthorized, .invalidClientID, .missingClientIdentifier, .webInternalError,
             .webContextAlreadyPresented, .invalidRecaptchaToken, .invalidRecaptchaAction, .invalidRecaptchaVersion:
            return .appVerificationFailed
        default: return .unavailable
        }
    }
}
