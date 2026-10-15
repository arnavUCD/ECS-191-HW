import XCTest

/// The launch flow through the real UI, against the app's DEBUG stand-in for Firebase
/// (`-SUAuthDemo <scenario>`): no Firebase users are created and no email is sent.
@MainActor
final class AuthFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUAuthDemo", scenario,
        ] + extra
        app.launch()
    }

    // MARK: - New user

    func testNewUserCreatesAccountVerifiesSetsUpAndEntersAnEmptyApp() {
        launch("fresh")
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 15), "A fresh install opens Welcome, not the app")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The app never shows before sign-in")
        screenshot("welcome")
        tap("welcome.createAccount")
        useEmail()

        XCTAssertTrue(element("auth.signUp").waitForExistence(timeout: 10))
        type("Maya Chen", into: "signUp.name")
        type("maya@example.com", into: "signUp.email")
        type("correct-horse-9", into: "signUp.password", secure: true)
        let reveal = element("signUp.password.reveal")
        XCTAssertEqual(reveal.label, "Show password", "The show/hide control has its own label and never reads the password")
        type("correct-horse-9", into: "signUp.confirmation", secure: true)
        XCTAssertTrue(labelContaining("Met: At least 8 characters").exists, "Requirements are stated in words")
        screenshot("sign-up-filled")
        tap("signUp.submit")

        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15), "Waits for email verification")
        XCTAssertEqual(element("verify.email").label, "Sent to maya@example.com")
        XCTAssertTrue(labelContaining("Resend email, available in").exists, "Resend starts on a cooldown")
        screenshot("verify-email")
        tap("verify.check")
        XCTAssertTrue(labelContaining("haven't seen the confirmation").waitForExistence(timeout: 10), "An unverified check explains itself")
        tap("verify.check")

        XCTAssertTrue(element("auth.profileName").waitForExistence(timeout: 15), "Verified: choose the name others see")
        XCTAssertEqual(element("profileSetup.name").value as? String, "Maya Chen", "The sign-up name is offered")
        screenshot("profile-name")
        tap("profileSetup.continue")

        XCTAssertTrue(element("auth.paymentSetup").waitForExistence(timeout: 15))
        tap("paymentSetup.later")
        XCTAssertTrue(element("auth.setupComplete").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("You're all set, Maya").exists)
        screenshot("setup-complete")
        tap("setupComplete.start")

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Into the app")
        XCTAssertTrue(labelContaining("Welcome, Maya").waitForExistence(timeout: 10), "A personalized, empty start")
        XCTAssertTrue(labelContaining("No groups yet").exists)
        XCTAssertFalse(labelContaining("Explore sample groups").exists, "No sample data for a real account")
        screenshot("empty-home")
    }

    func testSignUpValidatesBeforeSending() {
        launch("fresh")
        tap("welcome.createAccount")
        useEmail()
        XCTAssertTrue(element("auth.signUp").waitForExistence(timeout: 10))
        tap("signUp.submit")
        XCTAssertTrue(labelContaining("Enter the name people in your groups will see.").waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("Enter your email address.").exists)
        type("Maya", into: "signUp.name")
        type("maya@", into: "signUp.email")
        type("short", into: "signUp.password", secure: true)
        type("other", into: "signUp.confirmation", secure: true)
        XCTAssertTrue(labelContaining("Enter a valid email address").exists)
        XCTAssertTrue(labelContaining("The passwords don't match.").exists)
        XCTAssertTrue(labelContaining("Not met yet: At least 8 characters").exists)
        XCTAssertTrue(element("auth.signUp").exists, "Nothing was sent")
        screenshot("sign-up-issues")
    }

    func testAnEmailThatIsAlreadyUsedOffersSignIn() {
        launch("fresh")
        tap("welcome.createAccount")
        useEmail()
        type("Maya", into: "signUp.name")
        type("taken@example.com", into: "signUp.email")
        type("correct-horse-9", into: "signUp.password", secure: true)
        type("correct-horse-9", into: "signUp.confirmation", secure: true)
        tap("signUp.submit")
        XCTAssertTrue(element("signUp.failure").waitForExistence(timeout: 10))
        tap("signUp.signInInstead")
        XCTAssertTrue(element("auth.signIn").waitForExistence(timeout: 10))
    }

    // MARK: - Existing users

    func testExistingUserSignsInAfterAWrongPassword() {
        launch("fresh")
        tap("welcome.signIn")
        useEmail()
        XCTAssertTrue(element("auth.signIn").waitForExistence(timeout: 10))
        type("riley@example.com", into: "signIn.email")
        type("wrong-password", into: "signIn.password", secure: true)
        tap("signIn.submit")
        XCTAssertTrue(element("signIn.failure").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("don't match").exists, "Doesn't say whether the email has an account")
        screenshot("sign-in-failure")
        clearAndType("good-password-1", into: "signIn.password", secure: true)
        tap("signIn.submit")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "A verified account with a profile opens the app")
    }

    func testAnUnverifiedAccountSigningInGoesToVerification() {
        launch("fresh")
        tap("welcome.signIn")
        useEmail()
        type("unverified@example.com", into: "signIn.email")
        type("good-password-1", into: "signIn.password", secure: true)
        tap("signIn.submit")
        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testPasswordRecoverySendsALinkAndWaitsBeforeResending() {
        launch("fresh")
        tap("welcome.signIn")
        useEmail()
        type("maya@example.com", into: "signIn.email")
        tap("signIn.forgot")
        XCTAssertTrue(element("auth.resetPassword").waitForExistence(timeout: 10))
        XCTAssertEqual(element("reset.email").value as? String, "maya@example.com", "The address carries over")
        tap("reset.send")
        XCTAssertTrue(element("reset.sentTo").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("If an account uses this address").exists, "Same answer whether or not it has an account")
        XCTAssertFalse(element("reset.resend").isEnabled, "Resend waits out a cooldown")
        screenshot("reset-sent")
        tap("reset.backToSignIn")
        XCTAssertTrue(element("auth.signIn").waitForExistence(timeout: 10))
    }

    // MARK: - Relaunch, session end, sign-out

    func testRelaunchingWhileUnverifiedReturnsToVerificationAndCanSignOut() {
        launch("unverified")
        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15))
        tap("verify.signOut")
        tap("verify.confirmSignOut")
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 10))
    }

    func testAnEndedSessionReturnsToSignInWithAnExplanation() {
        launch("sessionEnded")
        XCTAssertTrue(element("auth.signIn").waitForExistence(timeout: 15))
        XCTAssertTrue(labelContaining("Your session ended").exists)
        XCTAssertEqual(element("signIn.email").value as? String, "riley@example.com")
    }

    func testAValidSessionOpensTheAppAndSignOutReturnsToWelcome() {
        launch("signedIn")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "A valid session needs no sign-in")
        openTab("Profile")
        let signOut = element("profile.account.signOut")
        for _ in 0..<8 where !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(labelContaining("riley@example.com").exists, "The signed-in email is shown")
        signOut.tap()
        element("profile.account.confirmSignOut").tap()
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 10), "Back to Welcome")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testOfflineLaunchOpensTheSavedData() {
        launch("offline")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Offline isn't signed out")
    }

    // MARK: - Invitations

    func testAnInvitationOpenedWhileSignedOutOpensAfterSignIn() {
        launch("fresh")
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 15))
        app.open(URL(string: "squp://join-group/ABCD-2EFG-H3JK-MN4P-QRS5")!)
        XCTAssertTrue(element("auth.pendingInvitation").waitForExistence(timeout: 10), "The invitation waits")
        tap("welcome.signIn")
        useEmail()
        XCTAssertTrue(element("auth.pendingInvitation").waitForExistence(timeout: 10), "…and stays visible while signing in")
        type("riley@example.com", into: "signIn.email")
        type("good-password-1", into: "signIn.password", secure: true)
        tap("signIn.submit")
        XCTAssertTrue(app.navigationBars["Join a group"].waitForExistence(timeout: 15), "It opens once the app is ready")
        screenshot("invitation-resumed")
    }

    // MARK: - Helpers

    /// Create account and Sign in open the phone screen first; these tests use email.
    private func useEmail() {
        let link = element("phone.useEmail")
        if link.waitForExistence(timeout: 10) { link.tap() }
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 10) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(identifier)")
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        target.tap()
    }

    private func type(_ text: String, into identifier: String, secure: Bool = false) {
        let field = secure ? app.secureTextFields[identifier].firstMatch : app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing field \(identifier)")
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(text)
    }

    private func clearAndType(_ text: String, into identifier: String, secure: Bool) {
        let field = secure ? app.secureTextFields[identifier].firstMatch : app.textFields[identifier].firstMatch
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(current.count, 20)))
        field.typeText(text)
    }

    private func openTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        for _ in 0..<8 where !button.isHittable { app.swipeDown() }
        button.tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
