import XCTest

/// End-to-end: the primary personal expense flow (CLAUDE.md §16 "XCUITest for the primary
/// personal expense flow"). Uses a throwaway in-memory store, a fixed clock, no tips, and the
/// rule-based parser so results never depend on Apple Intelligence availability.
@MainActor
final class PersonalExpenseFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-SUInMemoryStore", "-SUUITesting", "-SUReferenceDate", "812030400",
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

    func testAddEqualSplitExpenseUpdatesHome() {
        let add = element("home.addExpense")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        XCTAssertTrue(app.buttons["4"].waitForExistence(timeout: 5))
        // The composer defaults to the most recently active group; choose Apartment 4B explicitly.
        element("compose.group").tap()
        let apartment = app.buttons["Apartment 4B"].firstMatch
        XCTAssertTrue(apartment.waitForExistence(timeout: 5))
        apartment.tap()
        app.buttons["4"].tap()
        app.buttons["8"].tap()

        let title = app.textFields["compose.title"]
        title.tap()
        title.typeText("Pizza night\n")

        element("compose.next").tap()
        XCTAssertTrue(labelContaining("Adds up to the total").waitForExistence(timeout: 5))
        element("compose.review").tap()

        XCTAssertTrue(labelContaining("You paid $48.00 for Pizza night.").waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("$16.00 each").exists)
        element("compose.save").tap()

        // The sheet dismisses after the confirmation and Home shows the new expense.
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("Pizza night").waitForExistence(timeout: 5))
    }

    func testProminentTabOpensComposerAndCancelIsSafe() {
        let addTab = app.buttons["Add Expense"].firstMatch
        XCTAssertTrue(addTab.waitForExistence(timeout: 10))
        addTab.tap()
        XCTAssertTrue(app.buttons["4"].waitForExistence(timeout: 5))
        app.buttons["4"].tap()

        element("compose.cancel").tap()
        // Unsaved input asks before discarding; nothing is saved either way.
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 5))
        app.buttons["Discard"].tap()
        XCTAssertTrue(element("home.addExpense").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["4"].exists)
    }

    func testQuickEntryCreatesReviewableDraft() {
        let add = element("home.addExpense")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let quickEntry = element("compose.quickEntry")
        XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
        quickEntry.tap()

        let text = app.textViews["quickEntry.text"].exists ? app.textViews["quickEntry.text"] : app.textFields["quickEntry.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("I paid $45 for pizza with Maya")
        XCTAssertTrue(labelContaining("without AI").exists, "Discloses that the rule-based parser is in use")
        element("quickEntry.submit").tap()

        // Draft is applied but not saved: suggested fields are marked for review.
        XCTAssertTrue(labelContaining("review each field").waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("Suggested").exists)
        XCTAssertEqual(app.textFields["compose.title"].value as? String, "Pizza")
    }
}
