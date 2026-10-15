import Foundation
@testable import SquareUp
import Testing

/// The phone path through the launch flow and Profile → Sign-in methods, against a scripted
/// backend: no Firebase request, no text message. Numbers are Firebase-style fictional numbers.
@Suite("Phone sign-in · launch flow and linking")
@MainActor
struct PhoneSignInTests {
    private static let number = "+16505553434"

    /// A backend whose build has phone sign-in (Firebase's iOS app configured).
    private func phoneBackend() -> FakeAuthBackend {
        let backend = FakeAuthBackend()
        backend.isPhoneSignInAvailable = true
        return backend
    }

    private func signedOut(_ backend: FakeAuthBackend, clock: TestClock = TestClock(),
                           store: PendingPhoneVerificationStore = PendingPhoneVerificationStore(keychain: nil)) async -> AuthCoordinator {
        let auth = AuthCoordinator.make(backend, clock: clock, phoneVerifications: store)
        await auth.start()
        return auth
    }

    // MARK: - Entry

    @Test func welcomeKeepsBothChoicesAndEachOpensPhoneFirst() async {
        let auth = await signedOut(phoneBackend())
        #expect(auth.phase == .signedOut)
        auth.show(.createAccount)
        #expect(auth.phone.method(for: .createAccount) == .phone)
        auth.show(.signIn)
        #expect(auth.path == [.signIn], "Each choice opens its own screen; Back returns to Welcome")
        #expect(auth.phone.method(for: .signIn) == .phone)
    }

    @Test func useEmailInsteadSwitchesInPlaceAndKeepsTheNumber() async {
        let auth = await signedOut(phoneBackend())
        auth.show(.createAccount)
        auth.phone.draft = PhoneDraft(regionCode: "US", text: "(650) 555-3434")
        auth.phone.use(.email, for: .createAccount)
        #expect(auth.path == [.createAccount], "No extra screen: Back still goes to Welcome")
        #expect(auth.phone.method(for: .createAccount) == .email)
        #expect(auth.phone.method(for: .signIn) == .phone, "Sign in keeps its own choice")
        auth.phone.use(.phone, for: .createAccount)
        #expect(auth.phone.draft.text == "(650) 555-3434", "The number typed earlier is still there")
    }

    @Test func withoutPhoneInThisBuildBothChoicesUseEmail() async {
        let backend = FakeAuthBackend() // no phone in this build
        let auth = await signedOut(backend)
        #expect(auth.phone.method(for: .createAccount) == .email)
        #expect(auth.phone.method(for: .signIn) == .email)
        auth.phone.use(.phone, for: .signIn)
        #expect(auth.phone.method(for: .signIn) == .email)
    }

    // MARK: - Create account and sign in

    @Test func createAccountWithANewNumberAsksForTheNameThenOnboards() async throws {
        let backend = phoneBackend()
        backend.profileResult = .success(nil)
        let auth = await signedOut(backend)
        auth.show(.createAccount)
        try await auth.phone.sendCode(to: Self.number, purpose: .signUp)
        #expect(auth.path == [.createAccount, .phoneCode])
        #expect(auth.phone.notice == .sent)
        #expect(backend.sentNumbers == [Self.number], "E.164 is what's sent")
        try await auth.phone.verify(code: "123456")
        #expect(backend.enteredCodes == ["123456"])
        #expect(auth.phase == .needsProfile, "Phone accounts are verified by the code: no email step")
        #expect(auth.phone.outcome == .created)
        #expect(auth.phone.verification == nil && auth.path.isEmpty)
        try await auth.saveProfile(displayName: "Maya Chen")
        #expect(auth.phase == .onboarding(.paymentMethods))
    }

    @Test func signInWithAKnownNumberOpensTheApp() async throws {
        let backend = phoneBackend()
        backend.phoneSignInResult = .success(PhoneSignInResult(details: AuthFixtures.phoneAccount, isNewUser: false))
        let auth = await signedOut(backend)
        auth.show(.signIn)
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        try await auth.phone.verify(code: "123456")
        #expect(auth.phase == .ready)
        #expect(backend.preparedProfiles == [AuthFixtures.profile])
        #expect(auth.phone.outcome == nil)
    }

    @Test func signInWithANewNumberFinishesCreatingTheAccountInsteadOfLeavingItHalfMade() async throws {
        let backend = phoneBackend()
        backend.profileResult = .success(nil)
        let auth = await signedOut(backend)
        auth.show(.signIn)
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        try await auth.phone.verify(code: "123456")
        #expect(auth.phase == .needsProfile)
        #expect(auth.phone.outcome == .createdFromSignIn, "The name step says this number was new")
    }

    @Test func createAccountWithANumberThatHasAnAccountSignsInToIt() async throws {
        let backend = phoneBackend()
        backend.phoneSignInResult = .success(PhoneSignInResult(details: AuthFixtures.phoneAccount, isNewUser: false))
        backend.profileResult = .success(nil)
        let auth = await signedOut(backend)
        auth.show(.createAccount)
        try await auth.phone.sendCode(to: Self.number, purpose: .signUp)
        try await auth.phone.verify(code: "123456")
        #expect(auth.phone.outcome == .existingFromSignUp)
        #expect(auth.phase == .needsProfile)
    }

    // MARK: - Codes

    @Test func aWrongCodeKeepsTheCodeScreenAndItsVerification() async throws {
        let backend = phoneBackend()
        backend.phoneSignInResult = .failure(.account(.invalidCode))
        let auth = await signedOut(backend)
        auth.show(.createAccount)
        try await auth.phone.sendCode(to: Self.number, purpose: .signUp)
        await #expect(throws: AuthFailure.account(.invalidCode)) { try await auth.phone.verify(code: "000000") }
        #expect(auth.phase == .signedOut && auth.path == [.createAccount, .phoneCode])
        #expect(auth.phone.verification != nil, "Another try uses the same code")
        #expect(!auth.phone.isWorking)
    }

    @Test func resendWaitsOutAVisibleCooldownAndNeverDoubleSends() async throws {
        let clock = TestClock()
        let backend = phoneBackend()
        backend.sendCodeResults = [.success("verification-1"), .success("verification-2")]
        let auth = await signedOut(backend, clock: clock)
        auth.show(.signIn)
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        #expect(auth.phone.nextCodeAvailableAt == clock.now.addingTimeInterval(60))
        await auth.phone.resend()
        #expect(backend.count("sendCode") == 1, "Too soon: nothing is sent")
        clock.advance(61)
        #expect(auth.phone.nextCodeAvailableAt == nil)
        await auth.phone.resend()
        #expect(backend.count("sendCode") == 2)
        #expect(auth.phone.verification?.verificationID == "verification-2", "The newest code is the one checked")
        #expect(auth.phone.notice == .resent)
    }

    @Test func continuingAgainWithTheSameNumberReusesTheCodeAlreadySent() async throws {
        let backend = phoneBackend()
        let auth = await signedOut(backend)
        auth.show(.signIn)
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        auth.path.removeLast() // Back
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        #expect(backend.count("sendCode") == 1)
        #expect(auth.phone.notice == .alreadySent)
        #expect(auth.path == [.signIn, .phoneCode])
    }

    @Test func aDifferentNumberWithinTheCooldownIsHeldBack() async throws {
        let auth = await signedOut(phoneBackend())
        auth.show(.signIn)
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        auth.phone.changeNumber()
        #expect(auth.path == [.signIn] && auth.phone.verification == nil, "Change number goes back with the number as typed")
        await #expect(throws: AuthFailure.account(.codeCooldown)) { try await auth.phone.sendCode(to: "+16505550199", purpose: .signIn) }
    }

    @Test func theHourlyLimitStopsSendingAltogether() async throws {
        let clock = TestClock()
        let backend = phoneBackend()
        backend.sendCodeResults = (1...6).map { .success("verification-\($0)") }
        let auth = await signedOut(backend, clock: clock)
        auth.show(.signIn)
        for index in 0..<5 {
            try await auth.phone.sendCode(to: "+1650555010\(index)", purpose: .signIn)
            auth.phone.changeNumber()
            clock.advance(61)
        }
        #expect(auth.phone.isAtHourlyLimit)
        await #expect(throws: AuthFailure.account(.tooManyAttempts)) { try await auth.phone.sendCode(to: "+16505550109", purpose: .signIn) }
        #expect(backend.count("sendCode") == 5)
    }

    @Test func sendFailuresAreExplainedAndNothingIsRemembered() async {
        let backend = phoneBackend()
        backend.sendCodeResults = [.failure(.account(.smsQuotaExceeded))]
        let auth = await signedOut(backend)
        auth.show(.createAccount)
        await #expect(throws: AuthFailure.account(.smsQuotaExceeded)) { try await auth.phone.sendCode(to: Self.number, purpose: .signUp) }
        #expect(auth.phone.verification == nil && auth.path == [.createAccount])
        #expect(auth.phone.nextCodeAvailableAt == nil, "A send that failed doesn't start the cooldown")
    }

    // MARK: - Leaving and coming back

    @Test func aCodeSentBeforeARelaunchReturnsToCodeEntry() async throws {
        let clock = TestClock()
        let store = PendingPhoneVerificationStore(keychain: KeychainStore(service: "test.phone.\(UUID())"))
        let first = await signedOut(phoneBackend(), clock: clock, store: store)
        first.show(.createAccount)
        try await first.phone.sendCode(to: Self.number, purpose: .signUp)
        clock.advance(120) // to Messages and back, after iOS closed the app
        let relaunched = await signedOut(phoneBackend(), clock: clock, store: store)
        #expect(relaunched.path == [.createAccount, .phoneCode])
        #expect(relaunched.phone.verification?.phoneNumber == Self.number)
    }

    @Test func anOldCodeIsNotResumed() async throws {
        let clock = TestClock()
        let store = PendingPhoneVerificationStore(keychain: KeychainStore(service: "test.phone.\(UUID())"))
        let first = await signedOut(phoneBackend(), clock: clock, store: store)
        first.show(.signIn)
        try await first.phone.sendCode(to: Self.number, purpose: .signIn)
        clock.advance(PendingPhoneVerification.resumeWindow + 1)
        let relaunched = await signedOut(phoneBackend(), clock: clock, store: store)
        #expect(relaunched.path.isEmpty && relaunched.phone.verification == nil)
        #expect(store.load() == nil)
    }

    @Test func signingOutForgetsTheNumberAndAnyCodeInProgress() async throws {
        let backend = phoneBackend()
        backend.phoneSignInResult = .success(PhoneSignInResult(details: AuthFixtures.phoneAccount, isNewUser: false))
        let auth = await signedOut(backend)
        auth.show(.signIn)
        auth.phone.draft = PhoneDraft(regionCode: "US", text: "(650) 555-3434")
        try await auth.phone.sendCode(to: Self.number, purpose: .signIn)
        try await auth.phone.verify(code: "123456")
        await auth.signOut()
        #expect(auth.phase == .signedOut)
        #expect(auth.phone.draft == PhoneDraft() && auth.phone.verification == nil && auth.phone.outcome == nil)
        #expect(backend.count("signOut") == 1)
    }

    @Test func aStoredPhoneAccountIsNotMistakenForAnAnonymousOne() async {
        let backend = phoneBackend()
        backend.stored = AccountSession.StoredAccount(userID: "uid-phone", email: nil, emailVerified: nil, createdAt: AuthFixtures.created,
                                                      hasProfile: true, phoneNumber: Self.number)
        backend.restoreResult = .success(AuthFixtures.phoneAccount)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready, "A phone account restores and opens the app")
    }

    @Test func offlineAPhoneAccountStillOpensWithItsSavedData() async {
        let backend = phoneBackend()
        backend.stored = AccountSession.StoredAccount(userID: "uid-phone", email: nil, emailVerified: nil, createdAt: AuthFixtures.created,
                                                      hasProfile: true, phoneNumber: Self.number)
        backend.restoreResult = .failure(.account(.offline))
        backend.cached = AuthFixtures.profile
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready)
    }

    // MARK: - Adding a number to the signed-in account

    private func signedIn(_ backend: FakeAuthBackend) async -> AuthCoordinator {
        backend.stored = AuthFixtures.stored(verified: true)
        backend.restoreResult = .success(AuthFixtures.verified)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        return auth
    }

    @Test func addingANumberLinksItToTheSameAccount() async throws {
        let backend = phoneBackend()
        let auth = await signedIn(backend)
        try await auth.phone.sendCode(to: Self.number, purpose: .link)
        #expect(auth.path.isEmpty, "Linking happens in Profile, not over Welcome")
        #expect(auth.phone.pendingLink?.phoneNumber == Self.number)
        try await auth.phone.link(code: "123456")
        #expect(auth.details?.phoneNumber == Self.number)
        #expect(auth.details?.userID == AuthFixtures.verified.userID, "The same account, never a second one")
        #expect(auth.phone.pendingLink == nil)
        #expect(auth.phase == .ready)
    }

    @Test func aNumberUsedByAnotherAccountIsRefusedAndNeverMerged() async throws {
        let backend = phoneBackend()
        backend.linkResult = .failure(.account(.phoneInUse))
        let auth = await signedIn(backend)
        try await auth.phone.sendCode(to: Self.number, purpose: .link)
        await #expect(throws: AuthFailure.account(.phoneInUse)) { try await auth.phone.link(code: "123456") }
        #expect(auth.details == AuthFixtures.verified, "This account is unchanged")
        #expect(auth.phone.pendingLink == nil, "Start again with a different number")
        #expect(auth.phase == .ready)
        #expect(LedgerErrorMessages.text(for: AccountSession.Failure.phoneInUse).contains("another"))
    }

    @Test func aLinkThatFindsTheSessionEndedReturnsToSignIn() async throws {
        let backend = phoneBackend()
        backend.linkResult = .failure(.account(.sessionEnded))
        let auth = await signedIn(backend)
        try await auth.phone.sendCode(to: Self.number, purpose: .link)
        await #expect(throws: AuthFailure.account(.sessionEnded)) { try await auth.phone.link(code: "123456") }
        #expect(auth.phase == .signedOut && auth.notice == .sessionEnded)
    }
}

@Suite("Phone sign-in · throttle and pending code")
struct PhoneThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func oneMinuteBetweenCodes() {
        var throttle = PhoneSendThrottle()
        #expect(throttle.nextAllowed(at: start) == nil)
        throttle.record(at: start)
        #expect(throttle.nextAllowed(at: start.addingTimeInterval(30)) == start.addingTimeInterval(60))
        #expect(throttle.nextAllowed(at: start.addingTimeInterval(60)) == nil)
    }

    @Test func atMostFiveAnHourThenWaitForTheOldestToAge() {
        var throttle = PhoneSendThrottle()
        for minute in 0..<5 { throttle.record(at: start.addingTimeInterval(Double(minute) * 120)) }
        let later = start.addingTimeInterval(20 * 60)
        #expect(throttle.isAtHourlyLimit(at: later))
        #expect(throttle.nextAllowed(at: later) == start.addingTimeInterval(3600))
        #expect(throttle.nextAllowed(at: start.addingTimeInterval(3601)) == nil)
    }

    @Test func onlyTimesAreKept() throws {
        var throttle = PhoneSendThrottle()
        throttle.record(at: start)
        let encoded = try #require(String(bytes: JSONEncoder().encode(throttle), encoding: .utf8))
        #expect(!encoded.contains("+1") && !encoded.contains("650"), "No phone number is ever stored with the throttle")
    }

    @Test func pendingCodesExpireForResuming() {
        let pending = PendingPhoneVerification(purpose: .signIn, phoneNumber: "+16505553434", verificationID: "v", sentAt: start)
        #expect(pending.isFresh(at: start.addingTimeInterval(60)))
        #expect(!pending.isFresh(at: start.addingTimeInterval(PendingPhoneVerification.resumeWindow)))
    }
}
