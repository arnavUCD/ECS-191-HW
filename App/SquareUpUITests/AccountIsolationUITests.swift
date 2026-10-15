import XCTest

/// Multiple accounts on one iPhone, through the real UI, against the app's DEBUG stand-in for
/// Firebase (`-SUAuthDemo`): each account sees only its own groups; no unverified account opens the
/// app; an unverified sign-up can change its email or start over.
@MainActor
final class AccountIsolationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) {
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUAuthDemo", scenario,
        ]
        app.launch()
    }

    func testAccountsOnOneIPhoneNeverSeeEachOthersGroups() {
        launch("fresh")
        signIn("riley@example.com")
        createLocalGroup("Riley Only Trip")
        XCTAssertTrue(element("groups.row.Riley Only Trip").waitForExistence(timeout: 10))
        signOut()

        signIn("maya@example.com")
        openTab("Groups")
        XCTAssertTrue(labelContaining("No groups yet").waitForExistence(timeout: 10) || app.navigationBars["Groups"].exists)
        XCTAssertFalse(element("groups.row.Riley Only Trip").exists, "Maya never sees Riley's local group")
        createLocalGroup("Maya Dinner Club")
        screenshot("maya-groups")
        signOut()

        signIn("riley@example.com")
        openTab("Groups")
        XCTAssertTrue(element("groups.row.Riley Only Trip").waitForExistence(timeout: 10), "Riley's own group is back")
        XCTAssertFalse(element("groups.row.Maya Dinner Club").exists, "and nothing of Maya's")
        screenshot("riley-groups-again")
    }

    func testAnUnverifiedAccountWithAProfileMustVerifyBeforeTheAppOpens() {
        launch("unverifiedWithProfile")
        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15), "no exception, however old the account")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app doesn't open unverified")
        screenshot("must-verify")
        // The stand-in verifies on its second check (the screen makes a quiet one when it appears).
        for _ in 0..<3 where !app.tabBars.firstMatch.exists {
            XCTAssertTrue(element("auth.verifyEmail").exists, "still on verification until Firebase says verified")
            tap("verify.check")
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "verified: the app opens")
        openTab("Profile")
        let account = element("profile.account")
        for _ in 0..<8 where !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.label.contains("Verified"), "Profile shows the real state")
    }

    func testAnUnverifiedSignUpCanChangeItsEmail() {
        launch("unverified")
        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15))
        tap("verify.differentEmail")
        type("maya.chen@example.com", into: "changeEmail.email")
        tap("changeEmail.send")
        XCTAssertTrue(app.staticTexts["Sent to maya.chen@example.com"].waitForExistence(timeout: 10) ||
            element("verify.email").label == "Sent to maya.chen@example.com")
        screenshot("changed-email")
        tap("verify.check")
        tap("verify.check")
        XCTAssertTrue(element("auth.profileName").waitForExistence(timeout: 15), "the new address is verified and setup continues")
    }

    func testAnIncompleteSignUpCanStartOver() {
        launch("unverified")
        XCTAssertTrue(element("auth.verifyEmail").waitForExistence(timeout: 15))
        tap("verify.deleteAndRestart")
        tap("verify.confirmDelete")
        XCTAssertTrue(element("auth.signUp").waitForExistence(timeout: 15), "back to Create account")
    }

    // MARK: - Steps

    private func signIn(_ email: String) {
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 15))
        tap("welcome.signIn")
        useEmail()
        type(email, into: "signIn.email")
        type("good-password-1", into: "signIn.password", secure: true)
        tap("signIn.submit")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "signed in as \(email)")
        // iOS offers to save the password after a real sign-in; it covers the app until answered.
        _ = app.buttons["Not Now"].firstMatch.waitForExistence(timeout: 8)
        dismissSavePassword()
    }

    private func signOut() {
        openTab("Profile")
        let signOut = element("profile.account.signOut")
        for _ in 0..<8 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        tap("profile.account.confirmSignOut")
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 15), "signed out: Welcome, nothing else")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    private func createLocalGroup(_ name: String) {
        openTab("Groups")
        // The toolbar's New group, once the tab switch has settled (it isn't hittable mid-transition).
        let newGroup = element("groups.new")
        XCTAssertTrue(newGroup.waitForExistence(timeout: 10))
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: newGroup)
        wait(for: [settled], timeout: 10)
        newGroup.tap()
        let field = app.textFields["groupEditor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        tap("groupEditor.save")
        openTab("Groups")
        openTab("Groups") // back to the list
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

    /// iOS's "Save Password?" prompt can appear late and ignore a tap while it's still appearing:
    /// tap "Not Now" until it's gone, whenever it's on screen.
    private func dismissSavePassword() {
        let notNow = app.buttons["Not Now"].firstMatch
        for _ in 0..<5 where notNow.exists {
            if notNow.isHittable { notNow.tap() }
            _ = notNow.waitForNonExistence(timeout: 4)
        }
    }

    private func openTab(_ name: String) {
        dismissSavePassword()
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
