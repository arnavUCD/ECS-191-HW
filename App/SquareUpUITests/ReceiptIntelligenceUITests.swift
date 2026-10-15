import XCTest

/// Milestone 5: the AI-processing disclosure and the automatic fallback, through the real app UI,
/// with the bundled FICTIONAL sample receipt.
///
/// The first two tests point the app at a stopped server (nothing listens on port 1), so they need no
/// setup. The third is opt-in like `SharedRoomUITests`: `TEST_RUNNER_SQUAREUP_TEST_SERVER=<origin>` for a
/// local server started with `SQUAREUP_ALLOW_DEV_AUTH=1 SQUAREUP_AI_PROVIDER=recorded
/// SQUAREUP_AI_RECORDED_DIR=dev/recorded` (a recorded fictional answer; no API key, no provider call).
@MainActor
final class ReceiptIntelligenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let stoppedServer = "http://127.0.0.1:1"

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(server: String) {
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUSharedRoomsServer", server,
        ]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 15) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(identifier)")
        target.tap()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the sample receipt and answers the disclosure, which appears before anything is sent.
    private func startSample(choosing choice: String) {
        tap("home.scanReceipt")
        tap("receipt.sample")
        XCTAssertTrue(element("receipt.ai.consent").waitForExistence(timeout: 10), "The disclosure appears before the first AI-eligible receipt")
        screenshot("disclosure")
        tap(choice)
        XCTAssertTrue(element("review.reconciliation").waitForExistence(timeout: 30), "Review appears after the named stages")
    }

    func testOnDeviceOnlyChoiceKeepsTheReceiptOnTheDevice() {
        launch(server: Self.stoppedServer)
        startSample(choosing: "receipt.ai.decline")
        XCTAssertTrue(labelContaining("Read on this iPhone").exists)
        XCTAssertFalse(element("receipt.preparedOnDevice").exists, "Choosing on-device processing is not presented as a failure")
        XCTAssertTrue(labelContaining("Doesn't add up yet").exists, "The on-device result is unchanged from milestone 3")
        screenshot("review-on-device")
    }

    func testServerStoppedFallsBackAutomatically() {
        launch(server: Self.stoppedServer)
        startSample(choosing: "receipt.ai.accept")
        XCTAssertTrue(element("receipt.preparedOnDevice").waitForExistence(timeout: 5), "The calm fallback line is shown")
        XCTAssertTrue(labelContaining("Read on this iPhone").exists)
        XCTAssertTrue(element("review.continue").exists, "A complete, editable draft is ready")
        screenshot("review-fallback")
    }

    func testAIProcessingThroughLocalServer() throws {
        guard let server = ProcessInfo.processInfo.environment["SQUAREUP_TEST_SERVER"] else {
            throw XCTSkip("Set TEST_RUNNER_SQUAREUP_TEST_SERVER to a local server with the recorded AI provider")
        }
        launch(server: server)
        startSample(choosing: "receipt.ai.accept")
        XCTAssertTrue(labelContaining("Items identified with AI").waitForExistence(timeout: 5))
        XCTAssertFalse(element("receipt.preparedOnDevice").exists)
        XCTAssertTrue(labelContaining("Adds up exactly").exists, "The image's $8.50 was read; the total reconciles")
        screenshot("review-ai")
    }
}
