import XCTest

/// Milestone 2 end-to-end flows (milestone 2 §19 "UI tests"). Handoffs are simulated
/// (`-SUSimulateHandoffs`): no other app opens and no money moves.
@MainActor
final class SettlementFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-SUInMemoryStore", "-SUUITesting", "-SUSimulateHandoffs", "-SUReferenceDate", "812030400",
            "-allowOnDeviceAI", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func button(labelled text: String, excluding identifier: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", text, identifier)).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 5) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(identifier)")
        target.tap()
    }

    /// Home → Settle up → Pay Maya → Apple Cash → simulated Messages → "Yes, I sent it".
    private func reportPaymentToMaya() {
        tap("home.settleUp", timeout: 10)
        XCTAssertTrue(labelContaining("You pay Maya $29.69.").waitForExistence(timeout: 5))
        tap("plan.pay.Maya")
        XCTAssertTrue(element("pay.headline").waitForExistence(timeout: 5))
        XCTAssertEqual(element("pay.headline").label, "Pay Maya $29.69")
        tap("pay.method.appleCash")
        let primary = element("handoff.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.label, "Continue in Messages")
        primary.tap()
        // Opening Messages is never treated as paid: an explicit answer is required.
        XCTAssertTrue(element("handoff.question").waitForExistence(timeout: 5))
        XCTAssertEqual(element("handoff.question").label, "Did you send $29.69 to Maya?")
        XCTAssertFalse(labelContaining("Confirmed").exists)
        tap("handoff.yesSent")
        XCTAssertTrue(element("handoff.reported").waitForExistence(timeout: 5))
        tap("handoff.close")
    }

    func testCreateGroupWithMembers() {
        app.buttons["Groups"].firstMatch.tap()
        let newGroup = app.buttons["New group"].firstMatch
        XCTAssertTrue(newGroup.waitForExistence(timeout: 10))
        newGroup.tap()
        let name = app.textFields["groupEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Weekend Trip")
        let member = app.textFields["groupEditor.memberName"]
        member.tap()
        member.typeText("Taylor Kim\n")
        XCTAssertTrue(labelContaining("Taylor Kim").waitForExistence(timeout: 5))
        tap("groupEditor.save")
        // Lands on the new group's detail.
        XCTAssertTrue(app.navigationBars["Weekend Trip"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("group.addExpense").exists)
    }

    func testEditThenDeleteExpenseKeepsHistory() {
        app.buttons["Groups"].firstMatch.tap()
        tap("groups.row.Apartment 4B", timeout: 10)
        let costco = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Costco run")).firstMatch
        XCTAssertTrue(costco.waitForExistence(timeout: 5))
        costco.tap()

        tap("expense.edit")
        let title = app.textFields["compose.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" bulk\n")
        tap("compose.next")
        tap("compose.review")
        XCTAssertTrue(element("compose.changes").waitForExistence(timeout: 5))
        tap("compose.save")
        XCTAssertTrue(labelContaining("revision 2").waitForExistence(timeout: 10))

        tap("expense.delete")
        let confirm = button(labelled: "Delete expense", excluding: "expense.delete")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element("expense.deletedBanner").waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("deleted Costco run bulk").waitForExistence(timeout: 5), "History records the deletion")
    }

    func testPayConfirmAsRecipientSettles() {
        reportPaymentToMaya()
        // The plan no longer suggests the reported payment; it's awaiting Maya.
        let pending = labelContaining("You reported paying Maya")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        pending.tap()
        XCTAssertTrue(element("attempt.state").waitForExistence(timeout: 5))
        XCTAssertTrue(element("attempt.state").label.contains("Awaiting confirmation"))

        // Local prototype: respond as Maya (clearly labelled sample identity).
        tap("attempt.respondAsRecipient")
        XCTAssertTrue(labelContaining("Riley Park reported paying you $29.69 through Apple Cash").waitForExistence(timeout: 5))
        tap("confirm.received")
        XCTAssertTrue(element("success.screen").waitForExistence(timeout: 5))
        tap("success.done")
        XCTAssertTrue(element("attempt.confirmed").waitForExistence(timeout: 5))
    }

    func testRejectionRestoresObligation() {
        reportPaymentToMaya()
        let pending = labelContaining("You reported paying Maya")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        pending.tap()
        tap("attempt.respondAsRecipient")
        tap("confirm.notReceived")
        let confirm = button(labelled: "Not received", excluding: "confirm.notReceived")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(labelContaining("Maya didn't receive it").waitForExistence(timeout: 5))
        tap("attempt.payAgain")
        XCTAssertTrue(element("pay.headline").waitForExistence(timeout: 5))
        XCTAssertEqual(element("pay.headline").label, "Pay Maya $29.69", "The obligation is payable again")
    }

    func testRecipientConfirmsSeededPaymentFromHome() {
        XCTAssertTrue(labelContaining("Alex Rivera reported paying you $417.10 through Venmo").waitForExistence(timeout: 10))
        tap("confirm.received")
        XCTAssertTrue(element("success.screen").waitForExistence(timeout: 5))
        tap("success.done")
        XCTAssertFalse(labelContaining("Alex Rivera reported paying you").waitForExistence(timeout: 2))
    }

    func testProviderHandoffNeverClaimsSuccess() {
        tap("home.settleUp", timeout: 10)
        tap("plan.pay.Maya")
        tap("pay.method.paypal")
        XCTAssertEqual(element("handoff.primary").label, "Open PayPal")
        tap("handoff.primary")
        XCTAssertTrue(element("handoff.question").waitForExistence(timeout: 5))
        tap("handoff.notYet")
        XCTAssertTrue(element("handoff.primary").waitForExistence(timeout: 5), "Back to the options; nothing recorded")
        XCTAssertFalse(labelContaining("Confirmed").exists)
        tap("handoff.alreadySent")
        tap("handoff.cancelAttempt")
        // Cancelling closes the sheet; Maya is still owed the full amount.
        XCTAssertTrue(element("pay.headline").waitForExistence(timeout: 5))
        XCTAssertEqual(element("pay.headline").label, "Pay Maya $29.69")
    }
}
