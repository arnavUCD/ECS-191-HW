import XCTest

/// Two-device "Split with people now" (receipt split, October 2026; formerly the milestone 4 live
/// group room — group receipts no longer become live rooms), as two UI tests run
/// **at the same time on two simulators** against one development server. They coordinate
/// through files in a shared directory (simulators can read and write the Mac's file system).
///
/// Opt-in; both tests skip unless the runner gets:
/// - `SQUAREUP_TEST_SERVER` — e.g. `http://127.0.0.1:8080` (server with `SQUAREUP_ALLOW_DEV_AUTH=1`)
/// - `SQUAREUP_TWO_DEVICE_DIR` — an empty directory for the hand-off files
/// (pass them as `TEST_RUNNER_…` to `xcodebuild test-without-building`). See `server/README.md`.
@MainActor
final class SharedRoomUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private var handoff: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SQUAREUP_TEST_SERVER"], let directory = environment["SQUAREUP_TWO_DEVICE_DIR"] else {
            throw XCTSkip("Two-device test: set SQUAREUP_TEST_SERVER and SQUAREUP_TWO_DEVICE_DIR")
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

    // MARK: - Host (device 1)

    /// "Split with people now": the scanner paid, creates a temporary room, and shows the code.
    func testHostSharesResolvesAndFinalizes() throws {
        openRoom()
        tap("path.now", inScrollContent: false)
        XCTAssertTrue(element("splitNow.create").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("You paid").exists, "The scanner is the payer")
        screenshot("host-split-now")
        tap("splitNow.create", inScrollContent: false)
        let code = element("invite.code")
        if !code.waitForExistence(timeout: 20) { screenshot("host-after-create") }
        XCTAssertTrue(code.exists, "The invitation opens after creating the room")
        XCTAssertTrue(element("invite.qr").exists)
        // Read aloud as "A B C D - E F G H - …"; typed by the other device.
        let spoken = try XCTUnwrap(code.value as? String)
        let typed = spoken.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(typed.count, 14, "Twelve characters in three groups")
        XCTAssertFalse(labelContaining("App Clip").exists, "Never promises the App Clip before it's activated")
        screenshot("host-invite")
        signal("code", typed)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(labelContaining("host").waitForExistence(timeout: 5), "Status bar: You're Riley · host")
        XCTAssertFalse(element("room.switchIdentity").exists, "No identity switcher in a shared room")

        for item in ["Truffle Fries", "Mushroom Risotto", "Margherita Pizza", "Caesar Salad", "Shared Nachos", "Tiramisu", "Iced Tea"] {
            claim(item, "mine")
        }
        signal("hostClaimed")

        // The guest's claim and dispute arrive by polling — no refresh.
        XCTAssertTrue(labelContaining("Claimed by Maya").waitForExistence(timeout: 60), "Host sees Maya's claim from the other device")
        screenshot("host-sees-guest-claim")
        try waitFor("disputed", timeout: 400)
        XCTAssertTrue(labelContaining("Disputed by Maya").waitForExistence(timeout: 30), "Host sees Maya's dispute")
        XCTAssertFalse(element("room.finalReview").isEnabled, "An open dispute blocks finalization")
        screenshot("host-sees-dispute")
        tap("room.resolveDispute")
        replaceText(in: "resolve.note", with: "Tea was mine")
        tap("resolve.resolved", inScrollContent: false)
        XCTAssertTrue(labelContaining("Fully assigned").waitForExistence(timeout: 20))

        tap("room.finalReview", inScrollContent: false)
        XCTAssertTrue(element("final.save").waitForExistence(timeout: 15))
        screenshot("host-final-review")
        // Maya reviewed her share; if anything changed it since, the host has to say so explicitly.
        if element("final.unreviewed").exists { tap("final.acknowledge.Maya") }
        tap("final.save", inScrollContent: false)
        XCTAssertTrue(element("settle.header").waitForExistence(timeout: 20), "Finalized on the server: who pays you back")
        XCTAssertTrue(labelContaining("Final split").exists)
        screenshot("host-settle")
        signal("finalized")

        try waitFor("reported", timeout: 300)
        let confirm = element("settle.confirm.Maya")
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "Maya's report arrives by polling")
        confirm.tap()
        XCTAssertTrue(labelContaining("All square").waitForExistence(timeout: 20), "Everyone confirmed: the room closes")
        screenshot("host-all-square")
        signal("confirmed")
    }

    // MARK: - Participant (device 2)

    /// Joins by typing the short code (Home → Join a receipt), claims, disputes, reviews, then pays
    /// the payer back and sees the room close once they confirm.
    func testParticipantJoinsClaimsDisputesAndSeesTheResult() throws {
        let code = try waitFor("code", timeout: 300)
        tap("home.joinReceipt", timeout: 15, inScrollContent: false)
        let field = element("join.link")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(code.lowercased().replacingOccurrences(of: "-", with: " "))
        tap("join.continue", inScrollContent: false)

        let name = element("join.name")
        XCTAssertTrue(name.waitForExistence(timeout: 20), "A temporary room has no group seats: just a name")
        XCTAssertTrue(labelContaining("invited you").exists)
        name.tap()
        name.typeText("Maya")
        screenshot("participant-join")
        tap("join.submit", inScrollContent: false)
        XCTAssertTrue(labelContaining("You're Maya").waitForExistence(timeout: 20), "Opens the shared room as Maya")
        XCTAssertFalse(element("room.switchIdentity").exists)

        claim("Lemonade", "mine")
        XCTAssertTrue(labelContaining("Live · up to date").waitForExistence(timeout: 20))
        screenshot("participant-claimed")

        // The host's claims arrive here by polling. (Stale-revision conflicts are exercised by
        // RemoteRoomTests and LiveServerTests; a true race can't be forced through the UI.)
        try waitFor("hostClaimed", timeout: 300)
        XCTAssertTrue(labelContaining("Claimed by Riley").waitForExistence(timeout: 30), "Participant sees the host's claims")
        XCTAssertFalse(element("room.item.Mushroom Risotto.mine").exists, "Can't take an item someone else has fully claimed")
        screenshot("participant-sees-host-claims")

        tap("room.item.Iced Tea.more")
        app.buttons["Not mine / Dispute…"].firstMatch.tap()
        replaceText(in: "dispute.note", with: "I only had water")
        tap("dispute.send", inScrollContent: false)
        XCTAssertTrue(labelContaining("Disputed by Maya").waitForExistence(timeout: 20))
        tap("room.markReviewed")
        XCTAssertTrue(labelContaining("Reviewed").waitForExistence(timeout: 15), "Portion marked reviewed")
        signal("disputed")

        try waitFor("finalized", timeout: 300)
        XCTAssertTrue(element("settle.yourAmount").waitForExistence(timeout: 30), "What Maya owes Riley, once it's final")
        screenshot("participant-owes")
        tap("settle.paidOther", inScrollContent: false)
        XCTAssertTrue(element("settle.cancelReport").waitForExistence(timeout: 20), "Reported; waiting for Riley to confirm")
        signal("reported")

        try waitFor("confirmed", timeout: 300)
        XCTAssertTrue(labelContaining("All square").waitForExistence(timeout: 30), "Riley confirmed: all square")
        XCTAssertFalse(element("settle.paidOther").exists, "Nothing left to pay")
        screenshot("participant-all-square")
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
        // A timeout is a failure of the two-device flow, not a skip.
        throw HandoffTimeout(step: name)
    }

    // MARK: - Helpers (as in ReceiptRoomUITests)

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private lazy var screen: CGRect = app.windows.firstMatch.frame

    private func isVisible(_ target: XCUIElement) -> Bool {
        guard target.exists else { return false }
        let frame = target.frame
        return frame.minY > screen.minY + 250 && frame.maxY < screen.maxY - 190
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 10, inScrollContent: Bool = true) {
        let target = element(identifier)
        let found = target.waitForExistence(timeout: min(timeout, 3))
        if inScrollContent ? !isVisible(target) : !(found && target.isHittable) { scroll(to: target) }
        if !target.exists { _ = target.waitForExistence(timeout: timeout) }
        XCTAssertTrue(target.exists, "Missing \(identifier)")
        target.tap()
    }

    private func scroll(to target: XCUIElement) {
        let window = app.windows.firstMatch
        let lower = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let upper = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        var downward = !target.exists || target.frame.midY > screen.midY
        var attempts = 0
        while !isVisible(target), attempts < 24 {
            if downward { lower.press(forDuration: 0.01, thenDragTo: upper) } else { upper.press(forDuration: 0.01, thenDragTo: lower) }
            if target.exists { downward = target.frame.midY > screen.midY }
            attempts += 1
        }
        attempts = 0
        while !isVisible(target), attempts < 24 {
            upper.press(forDuration: 0.01, thenDragTo: lower)
            attempts += 1
        }
    }

    private func replaceText(in identifier: String, with text: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Missing \(identifier)")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }

    private func claim(_ item: String, _ action: String) { tap("room.item.\(item).\(action)") }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Home → Scan receipt → sample (with its deliberate misreading) → fix → continue → the two paths.
    private func openRoom() {
        tap("home.scanReceipt", timeout: 15, inScrollContent: false)
        tap("receipt.sample", inScrollContent: false)
        // With a server, the AI disclosure comes first (milestone 5): keep this receipt on the iPhone.
        if element("receipt.ai.consent").waitForExistence(timeout: 10) { tap("receipt.ai.decline", inScrollContent: false) }
        XCTAssertTrue(element("review.reconciliation").waitForExistence(timeout: 20))
        tap("review.item.Tiramisu")
        replaceText(in: "item.total", with: "8.50")
        tap("item.done", inScrollContent: false)
        XCTAssertTrue(labelContaining("Adds up exactly").waitForExistence(timeout: 5))
        tap("review.continue", inScrollContent: false)
        XCTAssertTrue(element("path.now").waitForExistence(timeout: 10))
    }
}
