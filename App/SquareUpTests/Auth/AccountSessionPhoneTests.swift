import Foundation
@testable import SquareUp
import Testing

/// Phone accounts in `AccountSession`: a phone sign-in from the Firebase SDK becomes the same
/// session email accounts use, and adding a number links it to the signed-in Firebase user
/// through Identity Toolkit — played by a scripted transport (no Firebase request, no SMS).
@Suite("Account session · phone")
struct AccountSessionPhoneTests {
    private typealias Kit = AccountSessionAuthTests
    private static let number = "+16505553434"

    private static let phoneSession = PhoneCredentialSession(userID: "uid-phone", idToken: "phone-id-token", refreshToken: "phone-refresh",
                                                             expiresIn: 3600, phoneNumber: number, isNewUser: true)

    private static func lookup(uid: String = "uid-phone", email: String? = nil, phone: String? = number) -> Data {
        var user: [String: Any] = ["localId": uid, "createdAt": "1792000000000"]
        if let email {
            user["email"] = email
            user["emailVerified"] = true
        }
        if let phone { user["phoneNumber"] = phone }
        return Kit.json(["users": [user]])
    }

    @Test func aPhoneSignInBecomesTheSessionEveryRequestUses() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let transport = ScriptedTransport { request, _ in
            Kit.method(request) == "accounts:lookup" ? (200, Self.lookup()) : (500, Data())
        }
        let session = Kit.session(transport, keychain: keychain)
        try await session.adopt(Self.phoneSession)
        #expect(try await session.authorizationHeader() == "Bearer phone-id-token", "The SDK's ID token, no extra refresh")
        let details = try await session.lookup()
        #expect(details.phoneNumber == Self.number && details.email == nil)
        let stored = try #require(await session.storedAccount)
        #expect(!stored.isAnonymous, "A phone account is a real account")
        #expect(stored.phoneNumber == Self.number)
        #expect(await session.isRecoverable, "It can hold shared groups and comes back on another iPhone")
        #expect(await session.status == .signedInWithPhone(Self.number))
        // Relaunch: the refresh token from the SDK is what's kept.
        let relaunched = Kit.session(ScriptedTransport { request, _ in
            request.url?.host() == "securetoken.googleapis.com"
                ? (200, Kit.json(["id_token": "fresh", "refresh_token": "phone-refresh", "expires_in": "3600"])) : (200, Self.lookup())
        }, keychain: keychain)
        #expect(try await relaunched.restore().phoneNumber == Self.number)
        #expect(try await relaunched.authorizationHeader() == "Bearer fresh")
    }

    @Test func signingOutForgetsAPhoneAccountLikeAnyOther() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let session = Kit.session(ScriptedTransport { _, _ in (500, Data()) }, keychain: keychain)
        try await session.adopt(Self.phoneSession)
        await session.signOut()
        #expect(await session.storedAccount == nil)
        #expect(AccountSession.rememberedUserID(keychain: keychain) == nil)
        await #expect(throws: AccountSession.Failure.signedOut) { _ = try await session.authorizationHeader() }
    }

    @Test func addingANumberLinksItToTheSignedInUserWithItsIDToken() async throws {
        let transport = ScriptedTransport { request, _ in
            switch Kit.method(request) {
            case "accounts:signInWithPassword": (200, Kit.tokens())
            case "accounts:signInWithPhoneNumber":
                (200, Kit.json(["idToken": "linked-id", "refreshToken": "linked-refresh", "expiresIn": "3600", "localId": "uid-maya",
                                "phoneNumber": Self.number]))
            case "accounts:lookup": (200, Self.lookup(uid: "uid-maya", email: "maya@example.com"))
            default: (500, Data())
            }
        }
        let session = Kit.session(transport)
        try await session.signIn(email: "maya@example.com", password: "secret")
        let details = try await session.linkPhone(verificationID: "verification-1", code: "123456")
        let link = await transport.requests[1]
        #expect(Kit.method(link) == "accounts:signInWithPhoneNumber")
        #expect(Kit.body(link)["idToken"] as? String == "id-token", "Linked to the signed-in user")
        #expect(Kit.body(link)["sessionInfo"] as? String == "verification-1")
        #expect(Kit.body(link)["code"] as? String == "123456")
        #expect(Kit.body(link)["operation"] as? String == "LINK")
        #expect(details.userID == "uid-maya" && details.phoneNumber == Self.number && details.email == "maya@example.com")
        #expect(try await session.authorizationHeader() == "Bearer linked-id")
    }

    @Test func aNumberThatBelongsToAnotherAccountIsReportedAsSuch() async throws {
        let transport = ScriptedTransport { request, _ in
            switch Kit.method(request) {
            case "accounts:signInWithPassword": (200, Kit.tokens())
            // Firebase's answer for a number already in use: a temporary proof, no tokens.
            case "accounts:signInWithPhoneNumber": (200, Kit.json(["temporaryProof": "proof", "phoneNumber": Self.number]))
            default: (500, Data())
            }
        }
        let session = Kit.session(transport)
        try await session.signIn(email: "maya@example.com", password: "secret")
        await #expect(throws: AccountSession.Failure.phoneInUse) { _ = try await session.linkPhone(verificationID: "v", code: "123456") }
        #expect(try await session.authorizationHeader() == "Bearer id-token", "The account's own session is untouched")
        #expect(await session.storedAccount?.userID == "uid-maya")
    }

    @Test func wrongAndExpiredCodesSayWhatHappened() {
        #expect(AccountSession.failure(for: "INVALID_CODE") == .invalidCode)
        #expect(AccountSession.failure(for: "SESSION_EXPIRED") == .codeExpired)
        #expect(AccountSession.failure(for: "INVALID_SESSION_INFO") == .codeExpired)
        #expect(AccountSession.failure(for: "INVALID_PHONE_NUMBER : TOO_SHORT") == .invalidPhoneNumber)
        #expect(AccountSession.failure(for: "PHONE_NUMBER_EXISTS") == .phoneInUse)
        #expect(AccountSession.failure(for: "TOO_MANY_ATTEMPTS_TRY_LATER") == .tooManyAttempts)
    }

    @Test func aLinkThatComesBackForADifferentUserIsRefused() async throws {
        let transport = ScriptedTransport { request, _ in
            switch Kit.method(request) {
            case "accounts:signInWithPassword": (200, Kit.tokens())
            case "accounts:signInWithPhoneNumber":
                (200, Kit.json(["idToken": "other", "refreshToken": "other", "expiresIn": "3600", "localId": "uid-someone-else"]))
            default: (500, Data())
            }
        }
        let session = Kit.session(transport)
        try await session.signIn(email: "maya@example.com", password: "secret")
        await #expect(throws: AccountSession.Failure.unavailable) { _ = try await session.linkPhone(verificationID: "v", code: "123456") }
        #expect(await session.storedAccount?.userID == "uid-maya", "Never switches to another account")
    }

    @Test func phoneRelatedMessagesArePlainAndNeverSayWhoHasAnAccount() {
        for failure: AccountSession.Failure in [.invalidPhoneNumber, .invalidCode, .codeExpired, .codeCooldown, .smsQuotaExceeded,
                                                .verificationCancelled, .appVerificationFailed, .phoneNotAllowed] {
            let text = LedgerErrorMessages.text(for: failure)
            #expect(!text.isEmpty)
            #expect(!text.localizedCaseInsensitiveContains("firebase"), "No service internals")
            #expect(!text.localizedCaseInsensitiveContains("no account"), "Never reveals whether a number is registered")
        }
    }
}

/// The bridge between Firebase's phone verification and the app's session, with a stand-in
/// verifier: what `LiveAuthBackend` does with a verified phone sign-in.
@Suite("Phone sign-in · session bridge")
@MainActor
struct PhoneSessionBridgeTests {
    final class StubVerifier: PhoneVerifying {
        var session = PhoneCredentialSession(userID: "uid-phone", idToken: "phone-id-token", refreshToken: "phone-refresh", expiresIn: 3600,
                                             phoneNumber: "+16505553434", isNewUser: true)
        var sendFailure: AccountSession.Failure?
        private(set) var sent: [String] = []

        func sendCode(to phoneNumber: String) async throws(AccountSession.Failure) -> String {
            if let sendFailure { throw sendFailure }
            sent.append(phoneNumber)
            return "verification-1"
        }

        func signIn(verificationID: String, code: String) async throws(AccountSession.Failure) -> PhoneCredentialSession {
            guard code == "123456" else { throw .invalidCode }
            return session
        }
    }

    @Test func aVerifiedPhoneOpensThatAccountsOwnSpace() async throws {
        let transport = ScriptedTransport { request, _ in
            AccountSessionAuthTests.method(request) == "accounts:lookup"
                ? (200, AccountSessionAuthTests.json(["users": [["localId": "uid-phone", "phoneNumber": "+16505553434"]]])) : (500, Data())
        }
        let account = AccountSessionAuthTests.session(transport)
        let session = AppSession(fixed: AppEnvironment(ledger: InMemoryLedgerStore(nil)))
        let verifier = StubVerifier()
        let backend = LiveAuthBackend(account: account, session: session, phone: verifier)
        #expect(backend.isPhoneSignInAvailable)
        #expect(try await backend.sendPhoneCode(to: "+16505553434") == "verification-1")
        await #expect(throws: AuthFailure.account(.invalidCode)) { _ = try await backend.signIn(phoneVerificationID: "verification-1", code: "000000") }
        let result = try await backend.signIn(phoneVerificationID: "verification-1", code: "123456")
        #expect(result.isNewUser && result.details.phoneNumber == "+16505553434")
        #expect(try await account.authorizationHeader() == "Bearer phone-id-token", "Server requests carry the phone account's token")
    }

    @Test func withoutAVerifierPhoneIsOffAndSaysSo() async {
        let account = AccountSessionAuthTests.session(ScriptedTransport { _, _ in (500, Data()) })
        let backend = LiveAuthBackend(account: account, session: AppSession(fixed: AppEnvironment(ledger: InMemoryLedgerStore(nil))), phone: nil)
        #expect(!backend.isPhoneSignInAvailable)
        await #expect(throws: AuthFailure.account(.notConfigured)) { _ = try await backend.sendPhoneCode(to: "+16505553434") }
    }

    @Test func firebasesRedirectIsTheOnlyURLItTakes() throws {
        #expect(FirebasePhoneVerifier.isFirebaseRedirect(try #require(URL(string: "app-1-123456789-ios-abcdef://firebaseauth/link?deep_link_id=x"))))
        #expect(!FirebasePhoneVerifier.isFirebaseRedirect(try #require(URL(string: "squp://join/SYNTHQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"))))
        #expect(!FirebasePhoneVerifier.isFirebaseRedirect(try #require(URL(string: "squp://join-group/ABCD-EFGH-JKMN-PQRS-TVWX"))))
        #expect(!FirebasePhoneVerifier.isFirebaseRedirect(try #require(URL(string: "https://square-up.example/r/SYNTHQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"))))
        #expect(!FirebasePhoneVerifier.isFirebaseRedirect(try #require(URL(string: "squp://scan"))))
    }

    @Test func phoneSignInNeedsTheMatchingRecaptchaSchemeRegistered() {
        let appID = "1:123456789:ios:abcdef0123456789"
        #expect(FirebasePhoneVerifier.callbackScheme(forGoogleAppID: appID) == "app-1-123456789-ios-abcdef0123456789")
        let registered: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["squp"]], ["CFBundleURLSchemes": ["app-1-123456789-ios-abcdef0123456789"]]]]
        let placeholder: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["squp"]], ["CFBundleURLSchemes": ["squp-firebase-not-configured"]]]]
        #expect(FirebasePhoneVerifier.registersCallbackScheme(for: appID, info: registered))
        #expect(!FirebasePhoneVerifier.registersCallbackScheme(for: appID, info: placeholder), "Off rather than crash on a missing scheme")
    }

    @Test func unsetBuildSettingsMeanNoFirebase() {
        #expect(FirebasePhoneVerifier.settings(from: [:]) == nil)
        #expect(FirebasePhoneVerifier.settings(from: ["SquareUpFirebaseGoogleAppID": "$(SQUAREUP_FIREBASE_GOOGLE_APP_ID)",
                                                      "SquareUpFirebaseGCMSenderID": "", "SquareUpFirebaseProjectID": "p"]) == nil)
        let complete: [String: Any] = ["SquareUpFirebaseGoogleAppID": "1:1:ios:1", "SquareUpFirebaseGCMSenderID": "1",
                                       "SquareUpFirebaseProjectID": "p", "SquareUpFirebaseAPIKey": "k"]
        #expect(FirebasePhoneVerifier.settings(from: complete)?.apiKey == "k", "The web key is the fallback for the iOS key")
    }
}
