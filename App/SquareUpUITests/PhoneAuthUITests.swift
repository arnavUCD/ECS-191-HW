import XCTest

/// Phone sign-up and sign-in through the real UI, against the app's DEBUG stand-in for Firebase
/// (`-SUAuthDemo`): fictional numbers and the fixed code 123456 — no text message is sent, no
/// Firebase user is created, and no SMS quota is used.
@MainActor
final class PhoneAuthUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String = "fresh") {
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUAuthDemo", scenario,
        ]
        app.launch()
    }

    func testCreateAccountWithAPhoneNumber() {
        launch()
        tap("welcome.createAccount", timeout: 15)
        XCTAssertTrue(element("auth.phoneSignUp").waitForExistence(timeout: 10), "Create account opens the phone screen first")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "No password for phone sign-up")
        XCTAssertTrue(labelContaining("Standard message rates may apply").exists)
        XCTAssertTrue(element("phone.useEmail").exists, "Email is one tap away")
        type("6505553434", into: "phone.number")
        XCTAssertEqual(element("phone.number").value as? String, "(650) 555-3434", "Formatted as typed")
        screenshot("phone-sign-up")
        tap("phone.continue")

        XCTAssertTrue(element("auth.phoneCode").waitForExistence(timeout: 10), "Then the code")
        XCTAssertTrue(labelContaining("+1 650-555-3434").exists, "The number the code went to")
        XCTAssertTrue(labelContaining("Resend code in").exists, "Resend waits out a visible cooldown")
        screenshot("phone-code")
        type("123456", into: "code.field")

        XCTAssertTrue(element("auth.profileName").waitForExistence(timeout: 15), "A new number chooses its name")
        type("Maya Chen", into: "profileSetup.name")
        tap("profileSetup.continue")
        XCTAssertTrue(element("auth.paymentSetup").waitForExistence(timeout: 15))
        tap("paymentSetup.later")
        tap("setupComplete.start", timeout: 10)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Into the app")
    }

    func testSignInWithAKnownNumberOpensTheApp() {
        launch()
        tap("welcome.signIn", timeout: 15)
        XCTAssertTrue(element("auth.phoneSignIn").waitForExistence(timeout: 10), "Sign in opens the phone screen first")
        type("6505551234", into: "phone.number")
        tap("phone.continue")
        XCTAssertTrue(element("auth.phoneCode").waitForExistence(timeout: 10))
        type("123456", into: "code.field")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "A known number signs straight in")
        XCTAssertFalse(element("auth.profileName").exists)
    }

    func testSignInWithANewNumberFinishesCreatingTheAccount() {
        launch()
        tap("welcome.signIn", timeout: 15)
        type("6505553434", into: "phone.number")
        tap("phone.continue")
        type("123456", into: "code.field")
        XCTAssertTrue(element("auth.profileName").waitForExistence(timeout: 15))
        XCTAssertTrue(element("profile.phoneNote").exists, "Explains that this number was new")
        screenshot("name-after-new-number")
    }

    func testWrongCodeChangeNumberAndEmailInstead() {
        launch()
        tap("welcome.createAccount", timeout: 15)
        type("6505553434", into: "phone.number")
        tap("phone.continue")
        XCTAssertTrue(element("auth.phoneCode").waitForExistence(timeout: 10))
        type("000000", into: "code.field")
        XCTAssertTrue(element("code.failure").waitForExistence(timeout: 10), "A wrong code is explained")
        XCTAssertTrue(labelContaining("isn't right").exists)
        screenshot("wrong-code")

        tap("code.changeNumber")
        XCTAssertTrue(element("auth.phoneSignUp").waitForExistence(timeout: 10))
        XCTAssertEqual(element("phone.number").value as? String, "(650) 555-3434", "Back with the number as typed")

        tap("phone.useEmail")
        XCTAssertTrue(element("auth.signUp").waitForExistence(timeout: 10), "The email form, in place")
        tap("signUp.usePhone")
        XCTAssertTrue(element("auth.phoneSignUp").waitForExistence(timeout: 10))
        XCTAssertEqual(element("phone.number").value as? String, "(650) 555-3434", "Switching keeps what was typed")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element("auth.welcome").waitForExistence(timeout: 10), "Back returns to the two choices")
    }

    func testInvalidNumberIsExplainedBeforeAnythingIsSent() {
        launch()
        tap("welcome.signIn", timeout: 15)
        type("650555", into: "phone.number")
        tap("phone.continue")
        XCTAssertTrue(labelContaining("too short").waitForExistence(timeout: 5))
        XCTAssertFalse(element("auth.phoneCode").exists, "Nothing was sent")
        tap("phone.number.country")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("United Kingdom")
        tap("country.GB")
        XCTAssertTrue(labelContaining("Country: United Kingdom, +44").waitForExistence(timeout: 5), "Any country, not just one")
    }

    func testAddAPhoneNumberToAnEmailAccount() {
        launch("signedIn")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        app.tabBars.buttons["Profile"].tap()
        scrollTo("profile.account.signInMethods").tap()
        tap("methods.addPhone")
        type("6505550123", into: "addPhone.number")
        tap("addPhone.send")
        XCTAssertTrue(element("addPhone.code").waitForExistence(timeout: 10))
        type("123456", into: "addPhone.code")
        XCTAssertTrue(element("methods.phone").waitForExistence(timeout: 15), "Linked to this account")
        XCTAssertTrue(labelContaining("+1 650-555-0123").exists)
        screenshot("sign-in-methods-linked")
    }

    func testANumberUsedByAnotherAccountIsNotMerged() {
        launch("signedIn")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        app.tabBars.buttons["Profile"].tap()
        scrollTo("profile.account.signInMethods").tap()
        tap("methods.addPhone")
        type("6505551234", into: "addPhone.number")
        tap("addPhone.send")
        type("123456", into: "addPhone.code")
        XCTAssertTrue(element("addPhone.failure").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("already used by another").exists, "Refused, never merged")
    }

    // MARK: - Helpers

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

    /// Profile is a lazy list: rows further down exist only once they're scrolled near.
    private func scrollTo(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<10 where !(target.exists && target.isHittable) { app.swipeUp() }
        XCTAssertTrue(target.exists, "Missing \(identifier)")
        return target
    }

    private func type(_ text: String, into identifier: String) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing field \(identifier)")
        field.tap()
        field.typeText(text)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
