import Foundation
@testable import SquareUp
import Testing

@Suite("Launch flow · restoring a session")
@MainActor
struct AuthLaunchTests {
    typealias Fix = AuthFixtures

    @Test func buildsWithoutAccountsOpenTheAppDirectly() async {
        let auth = AuthCoordinator.make(nil)
        #expect(auth.phase == .ready && !auth.isGated)
        await auth.start()
        #expect(auth.phase == .ready)
    }

    @Test func aFreshInstallStartsAtWelcomeWithoutAnyRequest() async {
        let backend = FakeAuthBackend()
        let auth = AuthCoordinator.make(backend)
        #expect(auth.phase == .restoring, "nothing of the app shows before the session is resolved")
        await auth.start()
        #expect(auth.phase == .signedOut && auth.path.isEmpty)
        #expect(backend.count("restore") == 0)
    }

    @Test func anOlderAnonymousAccountIsNotUsedToEnterTheApp() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: nil, email: nil)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .signedOut)
        #expect(backend.count("restore") == 0 && backend.count("signOut") == 0, "kept so creating an account upgrades it in place")
    }

    @Test func aValidSessionWithAProfileOpensTheApp() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready)
        #expect(backend.preparedProfiles == [Fix.profile])
        #expect(auth.email == "maya@example.com" && auth.isEmailVerified)
    }

    @Test func anUnverifiedNewAccountReturnsToVerification() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: false, hasProfile: nil)
        backend.restoreResult = .success(Fix.newAccount)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .verifyingEmail)
        #expect(backend.count("loadProfile") == 0, "an unverified account never reaches the app or its profile")
    }

    @Test func noAccountSkipsVerificationHoweverOldItIs() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: nil, createdAt: nil)
        backend.restoreResult = .success(Fix.oldUnverifiedAccount)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .verifyingEmail, "no date-based exemption")
        #expect(VerificationPolicy.requiresVerification(Fix.oldUnverifiedAccount) && VerificationPolicy.requiresVerification(Fix.newAccount))
        #expect(!VerificationPolicy.requiresVerification(Fix.verified))
        #expect(VerificationPolicy.requiresVerification(Fix.stored(verified: nil)), "an unknown remembered state isn't trusted")
        #expect(VerificationPolicy.requiresVerification(Fix.stored(verified: false)) && !VerificationPolicy.requiresVerification(Fix.stored(verified: true)))
    }

    @Test func offlineWithAnUnknownVerificationStateNeverOpensTheApp() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: nil)
        backend.restoreResult = .failure(.account(.offline))
        backend.cached = Fix.profile
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .verifyingEmail && auth.notice == .offline, "checked again once online")
        #expect(backend.count("signOut") == 0, "being offline never clears credentials")
    }

    @Test func aVerifiedAccountWithoutANameGoesToProfileSetup() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true, hasProfile: false)
        backend.restoreResult = .success(Fix.verified)
        backend.profileResult = .success(nil)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .needsProfile)
        #expect(auth.draftName == "Maya Chen", "the name typed at sign-up is offered again")
    }

    @Test func aRefusedRefreshTokenEndsTheSessionWithAnExplanation() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .failure(.account(.sessionEnded))
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .signedOut && auth.path == [.signIn])
        #expect(auth.notice == .sessionEnded)
        #expect(auth.rememberedEmail == "maya@example.com", "sign-in is prefilled")
        #expect(backend.count("signOut") == 1, "credentials and the account's cached data are cleared")
    }

    @Test func offlineWithAVerifiedAccountOpensTheSavedData() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .failure(.account(.offline))
        backend.cached = Fix.profile
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready, "being offline isn't being signed out")
        #expect(backend.count("signOut") == 0)
    }

    @Test func offlineWhileVerificationIsPendingStaysOnVerification() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: false, hasProfile: nil)
        backend.restoreResult = .failure(.account(.offline))
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .verifyingEmail && auth.notice == .offline)
    }

    @Test func offlineOnAFirstLaunchCanBeRetried() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true, hasProfile: nil)
        backend.restoreResult = .failure(.account(.offline))
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .unavailable && auth.notice == .offline)
        backend.restoreResult = .success(Fix.verified)
        await auth.retry()
        #expect(auth.phase == .ready)
    }

    @Test func aServiceFailureLoadingTheProfileFallsBackToTheSavedOne() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        backend.profileResult = .failure(.server("Unavailable"))
        backend.cached = Fix.profile
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready)
    }
}

@Suite("Launch flow · creating an account and signing in")
@MainActor
struct AuthSignUpAndSignInTests {
    typealias Fix = AuthFixtures

    private func signedOut(_ backend: FakeAuthBackend, clock: TestClock = TestClock()) async -> AuthCoordinator {
        let auth = AuthCoordinator.make(backend, clock: clock)
        await auth.start()
        return auth
    }

    @Test func creatingAnAccountSendsTheVerificationEmail() async throws {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        let auth = await signedOut(backend, clock: clock)
        auth.show(.createAccount)
        try await auth.signUp(Fix.form)
        #expect(auth.phase == .verifyingEmail && auth.path.isEmpty)
        #expect(backend.count("signUp") == 1 && backend.count("sendVerification") == 1)
        #expect(auth.verificationResendAvailableAt == clock.now.addingTimeInterval(AuthCoordinator.resendCooldown))
        #expect(auth.draftName == "Maya Chen", "trimmed")
        #expect(!auth.canResendVerification)
    }

    @Test func anAccountWhoseEmailCouldNotBeSentStillWaitsForVerification() async throws {
        let backend = FakeAuthBackend()
        backend.verificationResult = .failure(.account(.offline))
        let auth = await signedOut(backend)
        try await auth.signUp(Fix.form)
        #expect(auth.phase == .verifyingEmail && auth.notice == .verificationNotSent)
        #expect(auth.canResendVerification, "no cooldown when nothing was sent")
    }

    @Test(arguments: [AccountSession.Failure.emailInUse, .weakPassword, .invalidEmail, .tooManyAttempts, .offline])
    func signUpFailuresKeepThePersonOnTheForm(_ failure: AccountSession.Failure) async {
        let backend = FakeAuthBackend()
        backend.signUpResult = .failure(.account(failure))
        let auth = await signedOut(backend)
        auth.show(.createAccount)
        await #expect(throws: AuthFailure.account(failure)) { try await auth.signUp(Fix.form) }
        #expect(auth.phase == .signedOut && auth.path == [.createAccount])
        #expect(!auth.isWorking)
        #expect(!AuthFailure.account(failure).message.isEmpty)
    }

    @Test func aDoubleTapCreatesOneAccount() async throws {
        let backend = FakeAuthBackend()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        backend.hold = stream
        let auth = await signedOut(backend)
        async let first: Void = auth.signUp(Fix.form)
        // Wait until the first one is really running (one yield isn't enough on a busy machine).
        for _ in 0..<10_000 where !auth.isWorking { await Task.yield() }
        #expect(auth.isWorking)
        if auth.isWorking {
            try await auth.signUp(Fix.form) // ignored while the first is running
        }
        continuation.yield(())
        continuation.finish()
        try await first
        #expect(backend.count("signUp") == 1)
    }

    @Test func signingInWithAVerifiedAccountOpensTheApp() async throws {
        let backend = FakeAuthBackend()
        let auth = await signedOut(backend)
        auth.show(.signIn)
        try await auth.signIn(email: " maya@example.com", password: "secret-pass")
        #expect(auth.phase == .ready && auth.path.isEmpty)
    }

    @Test func signingInWithAnUnverifiedAccountGoesToVerificationWithoutResending() async throws {
        let backend = FakeAuthBackend()
        backend.signInResult = .success(Fix.newAccount)
        let auth = await signedOut(backend)
        try await auth.signIn(email: "maya@example.com", password: "secret-pass")
        #expect(auth.phase == .verifyingEmail)
        #expect(backend.count("sendVerification") == 0)
    }

    @Test func wrongDetailsAndBeingOfflineAreDifferentFailures() async {
        let backend = FakeAuthBackend()
        let auth = await signedOut(backend)
        backend.signInResult = .failure(.account(.invalidCredentials))
        await #expect(throws: AuthFailure.account(.invalidCredentials)) { try await auth.signIn(email: "a@b.co", password: "x") }
        backend.signInResult = .failure(.account(.offline))
        await #expect(throws: AuthFailure.account(.offline)) { try await auth.signIn(email: "a@b.co", password: "x") }
        #expect(AuthFailure.account(.offline).message != AuthFailure.account(.invalidCredentials).message)
        #expect(auth.phase == .signedOut)
    }

    @Test func passwordResetConfirmsAndThenWaitsBeforeResending() async throws {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        let auth = await signedOut(backend, clock: clock)
        try await auth.sendPasswordReset(email: " maya@example.com ")
        #expect(auth.resetSentTo == "maya@example.com")
        #expect(!auth.canResendPasswordReset)
        try await auth.sendPasswordReset(email: "maya@example.com")
        #expect(backend.count("sendReset") == 1, "a resend inside the cooldown does nothing")
        clock.advance(AuthCoordinator.resendCooldown)
        try await auth.sendPasswordReset(email: "maya@example.com")
        #expect(backend.count("sendReset") == 2)
        auth.editPasswordResetEmail()
        #expect(auth.resetSentTo == nil)
    }

    @Test func passwordResetFailuresAreReported() async {
        let backend = FakeAuthBackend()
        backend.resetResult = .failure(.account(.tooManyAttempts))
        let auth = await signedOut(backend)
        await #expect(throws: AuthFailure.account(.tooManyAttempts)) { try await auth.sendPasswordReset(email: "maya@example.com") }
        #expect(auth.resetSentTo == nil)
    }

    @Test func passwordRulesComeFromTheProjectPolicyOnce() async {
        let backend = FakeAuthBackend()
        backend.policy = AccountSession.PasswordPolicy(minimumLength: 10, requiresNumber: true)
        let auth = await signedOut(backend)
        await auth.loadPasswordRules()
        await auth.loadPasswordRules()
        #expect(auth.rules.minimumLength == 10 && auth.rules.requiresNumber)
        #expect(backend.count("policy") == 1)
    }
}

@Suite("Launch flow · verification, setup, invitations, signing out")
@MainActor
struct AuthVerificationAndSetupTests {
    typealias Fix = AuthFixtures

    private func verifying(_ backend: FakeAuthBackend, clock: TestClock = TestClock(),
                           invitations: PendingInvitationStore = PendingInvitationStore(keychain: nil)) async throws -> AuthCoordinator {
        let auth = AuthCoordinator.make(backend, clock: clock, invitations: invitations)
        await auth.start()
        try await auth.signUp(Fix.form)
        #expect(auth.phase == .verifyingEmail)
        return auth
    }

    @Test func returningToTheAppChecksQuietlyAndNotTooOften() async throws {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        let auth = try await verifying(backend, clock: clock)
        await auth.checkVerification(userInitiated: false)
        #expect(auth.notice == nil, "an automatic check that finds nothing says nothing")
        await auth.checkVerification(userInitiated: false)
        #expect(backend.count("reload") == 1, "throttled")
        clock.advance(AuthCoordinator.automaticCheckInterval)
        backend.reloadResults = [.success(Fix.verified)]
        backend.profileResult = .success(nil)
        await auth.checkVerification(userInitiated: false)
        #expect(auth.phase == .needsProfile, "verified in the browser, then back to the app")
    }

    @Test func tappingIveVerifiedExplainsWhenItIsNotDoneYet() async throws {
        let backend = FakeAuthBackend()
        let auth = try await verifying(backend)
        await auth.checkVerification(userInitiated: true)
        #expect(auth.phase == .verifyingEmail && auth.notice == .notVerifiedYet)
        backend.reloadResults = [.failure(.account(.offline))]
        await auth.checkVerification(userInitiated: true)
        #expect(auth.notice == .offline)
        backend.reloadResults = [.success(Fix.verified)]
        await auth.checkVerification(userInitiated: true)
        #expect(auth.phase == .ready, "a returning account with a profile opens the app")
    }

    @Test func anEndedSessionDuringVerificationReturnsToSignIn() async throws {
        let backend = FakeAuthBackend()
        let auth = try await verifying(backend)
        backend.reloadResults = [.failure(.account(.sessionEnded))]
        await auth.checkVerification(userInitiated: false)
        #expect(auth.phase == .signedOut && auth.notice == .sessionEnded)
    }

    @Test func resendingWaitsOutTheCooldown() async throws {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        let auth = try await verifying(backend, clock: clock)
        await auth.resendVerification()
        #expect(backend.count("sendVerification") == 1, "the sign-up email started the cooldown")
        clock.advance(AuthCoordinator.resendCooldown)
        await auth.resendVerification()
        #expect(backend.count("sendVerification") == 2 && auth.notice == .verificationSent)
        clock.advance(AuthCoordinator.resendCooldown)
        backend.verificationResult = .failure(.account(.tooManyAttempts))
        await auth.resendVerification()
        #expect(auth.notice == .problem(AuthFailure.account(.tooManyAttempts).message))
        #expect(!auth.canResendVerification, "Firebase's rate limit also starts a cooldown")
    }

    @Test func aDifferentEmailIsRequestedWithoutDeletingAnything() async throws {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        let auth = try await verifying(backend, clock: clock)
        try await auth.changeEmail(to: " maya.chen@example.com ")
        #expect(auth.pendingEmail == "maya.chen@example.com" && auth.phase == .verifyingEmail)
        #expect(backend.count("changeEmail") == 1 && backend.count("delete") == 0 && backend.count("signOut") == 0)
        #expect(auth.notice == .verificationSent && !auth.canResendVerification)
        // The link was opened: Firebase now reports the new address, verified.
        backend.reloadResults = [.success(AccountSession.AccountDetails(userID: "uid-maya", email: "maya.chen@example.com", emailVerified: true,
                                                                        displayName: "Maya Chen", createdAt: Fix.newAccount.createdAt))]
        backend.profileResult = .success(nil)
        await auth.checkVerification(userInitiated: true)
        #expect(auth.phase == .needsProfile && auth.pendingEmail == nil && auth.email == "maya.chen@example.com")
    }

    @Test func aFailedEmailChangeKeepsTheAccountAsItWas() async throws {
        let backend = FakeAuthBackend()
        backend.emailChangeResults = [.failure(.account(.offline)), .success(())]
        let auth = try await verifying(backend)
        await #expect(throws: AuthFailure.account(.offline)) { try await auth.changeEmail(to: "maya.chen@example.com") }
        #expect(auth.phase == .verifyingEmail && auth.pendingEmail == nil && auth.email == "maya@example.com")
        try await auth.changeEmail(to: "maya.chen@example.com") // retry after the partial failure
        #expect(auth.pendingEmail == "maya.chen@example.com")
    }

    @Test func aStaleSignInAsksToSignInAgainBeforeChanging() async throws {
        let backend = FakeAuthBackend()
        backend.emailChangeResults = [.failure(.account(.recentSignInRequired))]
        let auth = try await verifying(backend)
        await #expect(throws: AuthFailure.account(.recentSignInRequired)) { try await auth.changeEmail(to: "maya.chen@example.com") }
        #expect(auth.needsRecentSignIn && auth.phase == .verifyingEmail)
        await auth.signInAgain()
        #expect(auth.phase == .signedOut && auth.path == [.signIn] && auth.rememberedEmail == "maya@example.com")
    }

    @Test func anIncompleteSignUpCanBeDeletedAndStartedOver() async throws {
        let backend = FakeAuthBackend()
        backend.profileResult = .success(nil)
        let auth = try await verifying(backend)
        try await auth.deleteAndStartOver()
        #expect(backend.count("delete") == 1)
        #expect(auth.phase == .signedOut && auth.path == [.createAccount] && auth.draftName == "Maya Chen" && auth.email == nil)
    }

    @Test func deletingRetriesAfterAPartialFailure() async throws {
        let backend = FakeAuthBackend()
        backend.profileResult = .success(nil)
        backend.deleteResults = [.failure(.account(.offline)), .success(())]
        let auth = try await verifying(backend)
        await #expect(throws: AuthFailure.account(.offline)) { try await auth.deleteAndStartOver() }
        #expect(auth.phase == .verifyingEmail && auth.email == "maya@example.com", "nothing lost")
        try await auth.deleteAndStartOver()
        #expect(auth.phase == .signedOut && backend.count("delete") == 2)
    }

    @Test func establishedAccountsAreNeverDeleted() async throws {
        let backend = FakeAuthBackend()
        let auth = try await verifying(backend)
        // It already has a profile (set up on another iPhone).
        await #expect(throws: AuthFailure.self) { try await auth.deleteAndStartOver() }
        #expect(backend.count("delete") == 0 && auth.phase == .verifyingEmail)
    }

    @Test func firstRunGoesNameThenPaymentsThenWelcome() async throws {
        let backend = FakeAuthBackend()
        backend.profileResult = .success(nil)
        backend.reloadResults = [.success(Fix.verified)]
        let auth = try await verifying(backend)
        await auth.checkVerification(userInitiated: true)
        #expect(auth.phase == .needsProfile)
        try await auth.saveProfile(displayName: "  Maya Chen ")
        #expect(auth.phase == .onboarding(.paymentMethods))
        #expect(backend.preparedProfiles == [Fix.profile], "the app is prepared before it opens")
        auth.finishPaymentStep()
        #expect(auth.phase == .onboarding(.finished))
        auth.finishOnboarding()
        #expect(auth.phase == .ready)
    }

    @Test func aProfileThatCannotBeSavedKeepsTheNameStep() async throws {
        let backend = FakeAuthBackend()
        backend.profileResult = .success(nil)
        backend.saveResult = .failure(.account(.offline))
        backend.reloadResults = [.success(Fix.verified)]
        let auth = try await verifying(backend)
        await auth.checkVerification(userInitiated: true)
        await #expect(throws: AuthFailure.account(.offline)) { try await auth.saveProfile(displayName: "Maya") }
        #expect(auth.phase == .needsProfile && auth.draftName == "Maya")
    }

    @Test func anInvitationOpenedWhileSignedOutOpensOnceAfterSetup() async throws {
        let backend = FakeAuthBackend()
        backend.profileResult = .success(nil)
        backend.reloadResults = [.success(Fix.verified)]
        var delivered: [PendingInvitation] = []
        let auth = AuthCoordinator.make(backend)
        auth.deliverInvitation = { delivered.append($0) }
        await auth.start()
        auth.receive(.group(code: "ABCD2EFGH3JKMN4PQRS5"))
        #expect(auth.pendingInvitation == .group(code: "ABCD2EFGH3JKMN4PQRS5") && delivered.isEmpty)
        try await auth.signUp(Fix.form)
        await auth.checkVerification(userInitiated: true)
        try await auth.saveProfile(displayName: "Maya")
        auth.finishPaymentStep()
        #expect(delivered.isEmpty, "not until the app is open")
        auth.finishOnboarding()
        #expect(delivered == [.group(code: "ABCD2EFGH3JKMN4PQRS5")])
        #expect(auth.pendingInvitation == nil)
        auth.receive(.room(token: "room-token"))
        #expect(delivered.last == .room(token: "room-token"), "once ready, invitations open immediately")
    }

    @Test func aPendingInvitationSurvivesARelaunch() async throws {
        let keychain = KeychainStore(service: "test.auth.\(UUID())")
        let store = PendingInvitationStore(keychain: keychain)
        let first = AuthCoordinator.make(FakeAuthBackend(), invitations: store)
        await first.start()
        first.receive(.group(code: "ABCD2EFGH3JKMN4PQRS5"))
        // The app is quit during sign-in and launched again.
        let backend = FakeAuthBackend()
        var delivered: [PendingInvitation] = []
        let relaunched = AuthCoordinator.make(backend, invitations: store)
        relaunched.deliverInvitation = { delivered.append($0) }
        #expect(relaunched.pendingInvitation == .group(code: "ABCD2EFGH3JKMN4PQRS5"))
        await relaunched.start()
        try await relaunched.signIn(email: "maya@example.com", password: "secret-pass")
        #expect(delivered == [.group(code: "ABCD2EFGH3JKMN4PQRS5")])
        #expect(store.load() == nil, "used once, then forgotten")
    }

    @Test func signingOutReturnsToWelcome() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        backend.unsentChangeCount = 2
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready && auth.unsentChangeCount == 2)
        await auth.signOut()
        #expect(auth.phase == .signedOut && auth.path.isEmpty && auth.notice == .signedOut)
        #expect(auth.details == nil && auth.profile == nil)
        #expect(auth.email == nil && auth.rememberedEmail == nil, "the next person doesn't see who signed in before")
        #expect(backend.count("signOut") == 1)
    }

    @Test func aSessionThatEndsInsideTheAppReturnsToSignIn() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        await auth.sessionEnded()
        #expect(auth.phase == .signedOut && auth.path == [.signIn] && auth.notice == .sessionEnded)
        #expect(auth.rememberedEmail == "maya@example.com")
    }
}

@Suite("Launch flow · existing accounts and switching")
@MainActor
struct AuthExistingAccountTests {
    typealias Fix = AuthFixtures

    private static let oldVerified = AccountSession.AccountDetails(userID: "uid-riley", email: "riley@example.com", emailVerified: true,
                                                                   displayName: nil, createdAt: Fix.oldUnverifiedAccount.createdAt)

    @Test func anUnverifiedAccountWithAProfileStopsAtVerificationUntilVerified() async {
        let backend = FakeAuthBackend()
        let clock = TestClock()
        backend.stored = Fix.stored(verified: false, createdAt: Fix.oldUnverifiedAccount.createdAt, hasProfile: true)
        backend.restoreResult = .success(Fix.oldUnverifiedAccount)
        backend.cached = Fix.profile
        let auth = AuthCoordinator.make(backend, clock: clock)
        await auth.start()
        #expect(auth.phase == .verifyingEmail, "a profile and an old account earn no exception")
        #expect(backend.preparedProfiles.isEmpty, "the account's data isn't opened")

        await auth.resendVerification()
        #expect(backend.count("sendVerification") == 1 && auth.notice == .verificationSent && !auth.canResendVerification)
        await auth.resendVerification()
        #expect(backend.count("sendVerification") == 1, "the cooldown applies")

        backend.reloadResults = [.success(Fix.oldUnverifiedAccount)]
        await auth.checkVerification(userInitiated: false)
        #expect(auth.phase == .verifyingEmail && auth.notice == .verificationSent, "a quiet foreground check changes nothing")
        clock.advance(AuthCoordinator.automaticCheckInterval)
        backend.reloadResults = [.success(Self.oldVerified)]
        await auth.checkVerification(userInitiated: false)
        #expect(auth.phase == .ready && auth.isEmailVerified, "verified: the app opens")
    }

    @Test func verifiedAccountsAreNeverAsked() async {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready)
        await auth.resendVerification()
        await auth.checkVerification(userInitiated: true)
        #expect(backend.count("sendVerification") == 0 && backend.count("reload") == 0)
    }

    @Test func switchingAccountsRoutesEachOnItsOwnState() async throws {
        let backend = FakeAuthBackend()
        backend.stored = Fix.stored(verified: true)
        backend.restoreResult = .success(Fix.verified)
        let auth = AuthCoordinator.make(backend)
        await auth.start()
        #expect(auth.phase == .ready && auth.email == "maya@example.com")

        await auth.signOut()
        #expect(auth.phase == .signedOut && auth.details == nil && auth.profile == nil)
        backend.signInResult = .success(Fix.newAccount.with(userID: "uid-new", email: "new@example.com"))
        backend.profileResult = .success(nil)
        try await auth.signIn(email: "new@example.com", password: "secret-pass")
        #expect(auth.phase == .verifyingEmail && auth.email == "new@example.com", "the second account routes on its own state")

        await auth.signOut()
        backend.signInResult = .success(Fix.verified)
        backend.profileResult = .success(Fix.profile)
        try await auth.signIn(email: "maya@example.com", password: "secret-pass")
        #expect(auth.phase == .ready && auth.email == "maya@example.com" && auth.profile == Fix.profile)
        #expect(backend.count("signOut") == 2 && backend.preparedProfiles == [Fix.profile, Fix.profile])
    }
}

extension AccountSession.AccountDetails {
    func with(userID: String, email: String) -> AccountSession.AccountDetails {
        AccountSession.AccountDetails(userID: userID, email: email, emailVerified: emailVerified, displayName: displayName, createdAt: createdAt)
    }
}
