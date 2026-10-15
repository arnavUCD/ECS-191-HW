import XCTest

/// Milestone 3 end-to-end flows (milestone 3 §17.6) using the bundled FICTIONAL sample receipt and
/// its prerecorded recognition (one deliberate misreading). Camera capture is reviewed on a device.
@MainActor
final class ReceiptRoomUITests: XCTestCase {
    private var app: XCUIApplication!

    private let baseArguments = [
        "-SUUITesting", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = ["-SUInMemoryStore"]) {
        app.launchArguments = baseArguments + extra
        app.launch()
    }

    // MARK: Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private lazy var screen: CGRect = app.windows.firstMatch.frame

    /// On screen and clear of the pinned top and bottom bars (one frame query when it exists).
    private func isVisible(_ target: XCUIElement) -> Bool {
        guard target.exists else { return false }
        let frame = target.frame
        return frame.minY > screen.minY + 250 && frame.maxY < screen.maxY - 190
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 8, inScrollContent: Bool = true) {
        let target = element(identifier)
        let found = target.waitForExistence(timeout: min(timeout, 3))
        if inScrollContent ? !isVisible(target) : !(found && target.isHittable) { scroll(to: target) }
        if !target.exists { _ = target.waitForExistence(timeout: timeout) }
        XCTAssertTrue(target.exists, "Missing \(identifier)")
        target.tap()
    }

    /// Lazy lists render rows only near the viewport: search down, then back up.
    private func scroll(to target: XCUIElement) {
        let window = app.windows.firstMatch
        let lower = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let upper = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        // If it's rendered, scroll toward it; otherwise search downward, then upward. Stops as soon as it's visible.
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

    /// Switches toggle from the control itself, not the row's centre.
    private func toggle(_ identifier: String) {
        let row = element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing \(identifier)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replaceText(in identifier: String, with text: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Missing \(identifier)")
        // Tap at the trailing edge so the caret is after the existing text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }

    private func choose(_ menuIdentifier: String, option: String) {
        tap(menuIdentifier)
        let button = app.buttons[option].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing option \(option)")
        button.tap()
    }

    private func actAs(_ name: String) {
        tap("room.switchIdentity", inScrollContent: false)
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 15), "Missing identity \(name)")
        option.tap()
        XCTAssertTrue(labelContaining("Previewing as \(name.components(separatedBy: " ")[0])").waitForExistence(timeout: 5))
    }

    private func claim(_ item: String, _ action: String) {
        tap("room.item.\(item).\(action)")
    }

    /// Home → Scan receipt → sample → review with the deliberate misreading.
    private func startSampleReceipt() {
        tap("home.scanReceipt", timeout: 15, inScrollContent: false)
        tap("receipt.sample", inScrollContent: false)
        XCTAssertTrue(element("review.reconciliation").waitForExistence(timeout: 20), "Review appears after the named stages")
    }

    /// Corrects the misread Tiramisu line, continues, and chooses "Add to a group" → the group on
    /// this iPhone (the receipt-split choice: a group, or people now).
    private func reviewAndContinue() {
        XCTAssertTrue(labelContaining("Doesn't add up yet").waitForExistence(timeout: 5), "The misreading is visible, not hidden")
        XCTAssertFalse(element("review.continue").isEnabled, "Continue stays disabled while the math is off")
        screenshot("review-mismatch")
        tap("review.item.Tiramisu")
        replaceText(in: "item.total", with: "8.50")
        tap("item.done", inScrollContent: false)
        XCTAssertTrue(labelContaining("Adds up exactly").waitForExistence(timeout: 5), "The reconciliation updates immediately")
        XCTAssertTrue(element("review.statement").waitForExistence(timeout: 5), "No group needed to continue")
        XCTAssertEqual(element("review.statement").label,
                       "The receipt total is $104.04. 8 items and 3 additional charges account for the full amount.")
        screenshot("review-reconciled")
        tap("review.continue", inScrollContent: false)
        addToLocalGroup()
    }

    /// The two ways to split; "Add to a group" → Friday Dinner Crew → everyone, you paid.
    private func addToLocalGroup() {
        XCTAssertTrue(element("path.group").waitForExistence(timeout: 10), "Two paths after review")
        XCTAssertTrue(element("path.now").exists)
        screenshot("choose-path")
        tap("path.group", inScrollContent: false)
        tap("addToGroup.group.Friday Dinner Crew")
        XCTAssertTrue(element("addToGroup.post").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("You're hosting").exists, "The host is on the receipt")
        screenshot("add-to-group-people")
    }

    private func openRoom() {
        startSampleReceipt()
        reviewAndContinue()
        tap("addToGroup.post", inScrollContent: false)
        XCTAssertTrue(element("room.actingAs").waitForExistence(timeout: 10))
    }

    /// Everyone claims, including a three-way share.
    private func claimEverything() {
        // Each person claims in list order to keep scrolling short.
        claim("Truffle Fries", "share")
        claim("Mushroom Risotto", "mine")
        actAs("Maya")
        claim("Truffle Fries", "share")
        claim("Lemonade", "mine")
        actAs("Alex")
        claim("Margherita Pizza", "mine")
        claim("Shared Nachos", "share")
        claim("Iced Tea", "mine")
        actAs("Priya")
        claim("Caesar Salad", "mine")
        claim("Shared Nachos", "share")
        claim("Tiramisu", "mine")
    }

    // MARK: Tests

    /// §17.6 tests 1 and 2: import, correct an OCR mistake, resolve the mismatch, claim as
    /// several participants, finalize, and reopen the itemized expense.
    func testSampleReceiptBecomesItemizedExpense() {
        launch()
        openRoom()
        screenshot("room-open")
        claimEverything()
        actAs("Riley")
        XCTAssertTrue(labelContaining("Fully assigned").waitForExistence(timeout: 5), "Participant totals equal the receipt total")
        screenshot("room-complete")
        tap("room.finalReview", inScrollContent: false)
        XCTAssertTrue(element("final.statement").waitForExistence(timeout: 10))
        XCTAssertTrue(element("final.statement").label.contains("The $104.04 receipt is fully assigned."))
        screenshot("final-review")
        tap("final.save", inScrollContent: false)
        XCTAssertTrue(element("receipt.success").waitForExistence(timeout: 10))
        screenshot("success")
        tap("success.viewExpense", inScrollContent: false)
        XCTAssertTrue(element("expense.itemized").waitForExistence(timeout: 10))
        XCTAssertTrue(element("expense.itemizedProof").label.contains("exactly the receipt total"))
        XCTAssertTrue(element("expense.receiptPage").exists, "The receipt image is attached")
        screenshot("expense-detail")
    }

    /// §17.6 test 3: a shared item with exact-cent rounding disclosed.
    func testSharedItemDisclosesRounding() {
        launch()
        openRoom()
        claim("Truffle Fries", "share")
        tap("room.item.Truffle Fries.more")
        app.buttons["Assign or split…"].firstMatch.tap()
        XCTAssertTrue(element("split.mode").waitForExistence(timeout: 5))
        toggle("split.person.Maya")
        toggle("split.person.Priya")
        XCTAssertTrue(element("split.addsUp").waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("pays $0.01 more on Truffle Fries").waitForExistence(timeout: 5), "The cent of rounding is disclosed")
        screenshot("shared-item-editor")
        // Exact amounts must add up before saving.
        app.buttons["Exact"].firstMatch.tap()
        XCTAssertFalse(element("split.save").isEnabled)
        tap("split.save", timeout: 1, inScrollContent: false)
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// §17.6 test 4: create a dispute as a participant and resolve it as the host.
    func testDisputeAndResolution() {
        launch()
        openRoom()
        claimEverything()
        actAs("Maya")
        tap("room.item.Truffle Fries.more")
        app.buttons["Not mine / Dispute…"].firstMatch.tap()
        replaceText(in: "dispute.note", with: "I only had a couple")
        tap("dispute.send", inScrollContent: false)
        XCTAssertTrue(labelContaining("Disputed by Maya").waitForExistence(timeout: 5))
        actAs("Riley")
        XCTAssertFalse(element("room.finalReview").isEnabled, "An open dispute blocks finalization")
        screenshot("dispute-open")
        tap("room.resolveDispute")
        replaceText(in: "resolve.note", with: "Split stays even")
        tap("resolve.resolved", inScrollContent: false)
        XCTAssertTrue(labelContaining("Fully assigned").waitForExistence(timeout: 5))
        XCTAssertTrue(element("room.finalReview").isEnabled)
    }

    /// §17.6 test 6: tapping Save twice creates exactly one expense.
    func testDoubleFinalizeCreatesOneExpense() {
        launch()
        openRoom()
        claimEverything()
        actAs("Riley")
        tap("room.finalReview", inScrollContent: false)
        let save = element("final.save")
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        if save.exists, save.isHittable { save.tap() }
        XCTAssertTrue(element("receipt.success").waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Groups"].firstMatch.tap()
        tap("groups.row.Friday Dinner Crew", timeout: 10)
        let entries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "FERNWOOD SUPPER CLUB"))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(entries.count, 1, "Only one expense exists")
    }

    /// §17.6 test 5: a saved draft and an open room survive termination and relaunch.
    func testDraftAndRoomSurviveRelaunch() {
        launch(["-SUFreshStore"])
        startSampleReceipt()
        tap("review.item.Tiramisu")
        replaceText(in: "item.total", with: "8.50")
        tap("item.done", inScrollContent: false)
        XCTAssertTrue(labelContaining("Adds up exactly").waitForExistence(timeout: 5))
        sleep(2) // autosave pause
        app.terminate()

        launch([])
        XCTAssertTrue(element("home.receipts").waitForExistence(timeout: 15), "The draft is listed after relaunch")
        tap("receipt.unfinished")
        XCTAssertTrue(labelContaining("Adds up exactly").waitForExistence(timeout: 10), "The correction survived")
        tap("review.continue", inScrollContent: false)
        addToLocalGroup()
        tap("addToGroup.post", inScrollContent: false)
        claim("Tiramisu", "mine")
        app.terminate()

        launch([])
        tap("receipt.unfinished", timeout: 15, inScrollContent: false)
        XCTAssertTrue(element("room.actingAs").waitForExistence(timeout: 10), "The open room resumes")
        XCTAssertTrue(labelContaining("Yours").waitForExistence(timeout: 5), "The claim survived")
        screenshot("room-after-relaunch")
    }
}
