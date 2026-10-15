import XCTest

/// Milestone 7 §16.4, through the real app UI: two accounts on two simulators share one group.
///
/// Run at the same time on two simulators against one development server (each simulator has its
/// own Keychain, so each is a different account). They coordinate through files in a shared
/// directory. Opt-in; both skip unless the runner gets:
/// - `SQUAREUP_TEST_SERVER` — e.g. `http://127.0.0.1:8093` (server with `SQUAREUP_ALLOW_DEV_AUTH=1`)
/// - `SQUAREUP_TWO_DEVICE_DIR` — an empty directory for the hand-off files
/// (pass them as `TEST_RUNNER_…` to `xcodebuild test-without-building`). See `server/README.md`.
///
/// Riley creates a shared group and invites; Maya joins with the code; Riley adds an expense;
/// Maya sees the same split, settles up, and reports the payment sent; Riley confirms it on
/// Home; both see the group square.
@MainActor
final class SharedGroupUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private var handoff: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SQUAREUP_TEST_SERVER"], let directory = environment["SQUAREUP_TWO_DEVICE_DIR"] else {
            throw XCTSkip("Two-account test: set SQUAREUP_TEST_SERVER and SQUAREUP_TWO_DEVICE_DIR")
        }
        self.server = server
        handoff = URL(filePath: directory)
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUSharedRoomsServer", server,
        ]
        app.launch()
    }

    // MARK: - Riley (device 1)

    func testOwnerCreatesInvitesAddsExpenseAndConfirmsPayment() throws {
        setName("Riley")
        let groupName = "UI Trip \(Int.random(in: 1000...9999))"
        openTab("Groups")
        tap("groups.new", inScrollContent: false)
        let shared = app.segmentedControls["groupEditor.location"].buttons["Shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 10), "Create group offers a shared group")
        shared.tap()
        XCTAssertTrue(labelContaining("everyone you invite sees the same expenses").exists, "The difference is explained before creating")
        let name = app.textFields["groupEditor.name"]
        name.tap()
        name.typeText(groupName)
        tap("groupEditor.save", inScrollContent: false)

        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 20), "Opens the new shared group")
        XCTAssertTrue(labelContaining("Shared · up to date").waitForExistence(timeout: 20))
        screenshot("owner-shared-group")
        tap("group.people", inScrollContent: false)
        tap("sharedGroup.invite")
        let code = element("groupInvite.code")
        XCTAssertTrue(code.waitForExistence(timeout: 20), "An invitation code appears")
        XCTAssertTrue(element("groupInvite.qr").exists && element("groupInvite.copyCode").exists && element("groupInvite.share").exists)
        XCTAssertFalse(labelContaining("universal link").exists)
        let value = try XCTUnwrap(code.value as? String).replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(value.count, 24, "XXXX-XXXX-XXXX-XXXX-XXXX")
        screenshot("owner-invite")
        signal("name", groupName)
        signal("code", value)
        app.buttons["Done"].firstMatch.tap()

        try waitFor("joined", timeout: 300)
        XCTAssertTrue(labelContaining("Maya").waitForExistence(timeout: 60), "Maya appears in People once she joins")
        screenshot("owner-people")
        app.buttons["Done"].firstMatch.tap()

        // An expense: $60.00 for gas, split equally between the two of them.
        tap("group.addExpense", inScrollContent: false)
        XCTAssertTrue(app.buttons["6"].waitForExistence(timeout: 10))
        app.buttons["6"].tap()
        app.buttons["0"].tap()
        let title = app.textFields["compose.title"]
        title.tap()
        title.typeText("Gas\n")
        tap("compose.next", inScrollContent: false)
        XCTAssertTrue(labelContaining("Adds up to the total").waitForExistence(timeout: 10))
        tap("compose.review", inScrollContent: false)
        XCTAssertTrue(labelContaining("$30.00 each").waitForExistence(timeout: 10))
        tap("compose.save", inScrollContent: false)
        XCTAssertTrue(labelContaining("Gas").waitForExistence(timeout: 20))
        signal("expense")

        // Maya reports paying; Riley confirms on Home (only the recipient's confirmation settles it).
        try waitFor("reported", timeout: 300)
        openTab("Home")
        let confirm = element("confirm.received")
        XCTAssertTrue(confirm.waitForExistence(timeout: 90), "The reported payment appears on Home without opening the group")
        screenshot("owner-home-confirm")
        confirm.tap()
        XCTAssertTrue(element("success.screen").waitForExistence(timeout: 30), "Confirmed by the server")
        screenshot("owner-confirmed")
        tap("success.done", inScrollContent: false)
        signal("confirmed")
    }

    // MARK: - Maya (device 2)

    func testMemberJoinsWithCodeSeesTheSplitAndPays() throws {
        setName("Maya")
        let code = try waitFor("code", timeout: 300)
        app.open(URL(string: "squp://join-group/\(code)")!)
        XCTAssertTrue(element("joinGroup.preview").waitForExistence(timeout: 30), "A safe preview before joining")
        XCTAssertTrue(labelContaining("Riley invited you").exists)
        screenshot("member-preview")
        tap("joinGroup.join", inScrollContent: false)
        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 30), "Joins and opens the group")
        signal("joined")

        try waitFor("expense", timeout: 300)
        XCTAssertTrue(labelContaining("Gas").waitForExistence(timeout: 60), "Riley's expense arrives by polling")
        screenshot("member-sees-expense")
        // The row reads "Gas, Riley paid $60.00 · …, you borrowed, 30 dollars" (amounts are spoken in labels).
        XCTAssertTrue(labelContaining("Riley paid $60.00").waitForExistence(timeout: 30), "Maya sees who paid")
        XCTAssertTrue(labelContaining("you borrowed").exists, "Maya sees her share of the identical split")

        tap("group.settleUp", inScrollContent: false)
        tap("plan.pay.Riley")
        XCTAssertTrue(element("pay.headline").waitForExistence(timeout: 20))
        XCTAssertEqual(element("pay.headline").label, "Pay Riley $30.00")
        tap("pay.manual")
        if element("handoff.alreadySent").waitForExistence(timeout: 10) { element("handoff.alreadySent").tap() }
        tap("handoff.yesSent", inScrollContent: false)
        XCTAssertTrue(element("handoff.reported").waitForExistence(timeout: 30), "Waiting for Riley — shown only after the server accepted it")
        screenshot("member-reported")
        tap("handoff.close", inScrollContent: false)
        signal("reported")

        try waitFor("confirmed", timeout: 300)
        let groupName = try waitFor("name", timeout: 10)
        openTab("Home")
        openTab("Groups")
        openTab("Groups") // pops to the list
        tap("groups.row.\(groupName)")
        XCTAssertTrue(labelContaining("you're all square").waitForExistence(timeout: 90), "Riley's confirmation settles Maya's balance too")
        screenshot("member-square")
    }

    // MARK: - Steps

    private func setName(_ name: String) {
        openTab("Profile")
        let choose = element("profile.account.chooseName")
        let change = element("profile.account.changeName")
        let deadline = Date.now.addingTimeInterval(30)
        // The Account section is near the bottom of Profile; scroll until its button loads.
        while !choose.isHittable && !change.isHittable && Date.now < deadline {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        (choose.exists ? choose : change).tap()
        let field = app.textFields["account.displayName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "Your name" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(name)
        tap("account.saveName", inScrollContent: false)
        XCTAssertTrue(labelContaining(name).waitForExistence(timeout: 20))
    }

    // MARK: - Hand-off files

    struct HandoffTimeout: Error, CustomStringConvertible {
        let step: String
        var description: String { "The other device didn't reach '\(step)' in time" }
    }

    private func signal(_ name: String, _ content: String = "1") {
        try? content.write(to: handoff.appending(path: name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func waitFor(_ name: String, timeout: TimeInterval) throws -> String {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let content = try? String(contentsOf: handoff.appending(path: name), encoding: .utf8) { return content }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw HandoffTimeout(step: name)
    }

    // MARK: - Helpers (as in SharedRoomUITests)

    /// The tab bar minimizes while scrolling (iOS 27); scroll back up until the tab is tappable.
    private func openTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        for _ in 0..<8 where !button.isHittable { app.swipeDown() }
        button.tap()
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 15, inScrollContent: Bool = true) {
        let target = element(identifier)
        if !target.waitForExistence(timeout: timeout) { screenshot("missing-\(identifier)") }
        XCTAssertTrue(target.exists, "Missing \(identifier)")
        if inScrollContent, !target.isHittable {
            for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        }
        target.tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
