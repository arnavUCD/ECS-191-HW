import XCTest

/// Multi-person shared groups through the real UI, on one simulator: the app is the owner; the
/// other people are development accounts that join over HTTP from the test (no Firebase users).
///
/// Opt-in; skips unless the runner gets `SQUAREUP_TEST_SERVER` (e.g. `http://127.0.0.1:8093`, a
/// server started with `SQUAREUP_ALLOW_DEV_AUTH=1`; pass it as `TEST_RUNNER_SQUAREUP_TEST_SERVER`).
///
/// Riley creates a shared group (just Riley), makes separate invitations for Maya and Sam, sees each
/// accepted, turns off a third, removes Sam (nothing owed), and sees Sam under past members.
@MainActor
final class MultiPersonGroupUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private let run = String(Int.random(in: 100_000...999_999))

    override func setUp() async throws {
        continueAfterFailure = false
        guard let server = ProcessInfo.processInfo.environment["SQUAREUP_TEST_SERVER"] else {
            throw XCTSkip("Set SQUAREUP_TEST_SERVER to run against a development server")
        }
        self.server = server
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUSharedRoomsServer", server,
        ]
        app.launch()
    }

    func testOwnerInvitesSeveralPeopleSeesEachStateAndRemovesSomeone() throws {
        setName("Riley")
        let groupName = "Lake House \(run)"
        openTab("Groups")
        tap("groups.new", inScrollContent: false)
        let shared = app.segmentedControls["groupEditor.location"].buttons["Shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        shared.tap()
        XCTAssertTrue(element("groupEditor.sharedPeople").waitForExistence(timeout: 5), "A shared group starts with just you")
        XCTAssertFalse(app.textFields["groupEditor.memberName"].exists, "nobody is added by name")
        let name = app.textFields["groupEditor.name"]
        name.tap()
        name.typeText(groupName)
        tap("groupEditor.save", inScrollContent: false)
        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 20))

        // Two invitations, one per person.
        tap("group.people", inScrollContent: false)
        XCTAssertTrue(labelContaining("1 of 25 people").waitForExistence(timeout: 20))
        tap("sharedGroup.invite")
        let maya = try code()
        tap("groupInvite.another")
        let sam = try code(differentFrom: maya)
        XCTAssertNotEqual(maya, sam)
        screenshot("second-invitation")
        tap("groupInvite.done", inScrollContent: false)
        XCTAssertTrue(element("sharedGroup.awaiting").waitForExistence(timeout: 20), "both wait to be accepted")

        // Maya and Sam join from their own (development) accounts.
        try join(code: maya, as: "maya-\(run)", name: "Maya")
        try join(code: sam, as: "sam-\(run)", name: "Sam")
        XCTAssertTrue(element("sharedGroup.person.Maya").waitForExistence(timeout: 60), "Maya appears once she joins")
        XCTAssertTrue(element("sharedGroup.person.Sam").waitForExistence(timeout: 60))
        XCTAssertTrue(labelContaining("3 of 25 people").waitForExistence(timeout: 30))
        XCTAssertTrue(labelContaining("Accepted by Maya").waitForExistence(timeout: 30), "the owner sees who used each invitation")
        XCTAssertTrue(labelContaining("Accepted by Sam").exists)
        screenshot("both-joined")

        // A third invitation, turned off before anyone uses it.
        tap("sharedGroup.invite")
        _ = try code()
        tap("groupInvite.revoke")
        XCTAssertTrue(labelContaining("Turned off").waitForExistence(timeout: 20))
        XCTAssertFalse(element("groupInvite.code").exists, "a turned-off invitation no longer shows its code")
        tap("groupInvite.done", inScrollContent: false)
        XCTAssertTrue(labelContaining("Turned off").waitForExistence(timeout: 20), "listed with the ended invitations")

        // Sam owes nothing, so the owner can remove him; he's listed as a past member.
        let options = app.buttons["Options for Sam"]
        for _ in 0..<6 where !options.isHittable { app.swipeUp() }
        options.tap()
        app.buttons["Remove from group"].firstMatch.tap()
        let remove = app.buttons["sharedGroup.confirm"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        XCTAssertTrue(element("sharedGroup.former").waitForExistence(timeout: 30))
        XCTAssertTrue(element("sharedGroup.former").label.contains("Sam"))
        XCTAssertFalse(element("sharedGroup.person.Sam").exists)
        XCTAssertTrue(labelContaining("To leave, first make someone else the owner").exists, "the owner can't just leave")
        screenshot("sam-removed")
    }

    // MARK: - Other people, over HTTP as development accounts

    private func join(code: String, as uid: String, name: String) throws {
        let profile = try request("PUT", "/v1/account/profile", as: uid, body: ["displayName": name, "locale": "en_US"])
        XCTAssertEqual(profile, 200)
        let accepted = try request("POST", "/v1/group-invitations/\(code)/accept", as: uid, body: ["displayName": name])
        XCTAssertEqual(accepted, 201, "\(name) joins")
    }

    private func request(_ method: String, _ path: String, as uid: String, body: [String: Any]) throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        request.setValue("Dev \(uid)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        final class Box: @unchecked Sendable { var status = 0 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return box.status
    }

    // MARK: - Steps

    private func code(differentFrom previous: String? = nil) throws -> String {
        let field = element("groupInvite.code")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "An invitation code appears")
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            let value = (field.value as? String)?.replacingOccurrences(of: " ", with: "") ?? ""
            if value.count == 24, value != previous { return value }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw XCTSkip("No new invitation code appeared")
    }

    private func setName(_ name: String) {
        openTab("Profile")
        let choose = element("profile.account.chooseName")
        let change = element("profile.account.changeName")
        let deadline = Date.now.addingTimeInterval(30)
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
