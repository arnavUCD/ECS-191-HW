import XCTest

/// Direct invitations ("Find a person") through the real UI, against a development server. Opt-in;
/// skips unless the runner gets `SQUAREUP_TEST_SERVER` (e.g. `http://127.0.0.1:8093`, a server
/// started with `SQUAREUP_ALLOW_DEV_AUTH=1`; pass it as `TEST_RUNNER_SQUAREUP_TEST_SERVER`).
///
/// The app runs as a development account with a known identity (`-SUDevUserID`), so its address on
/// that server is `<id>@squareup.test`; other people are development accounts over HTTP.
@MainActor
class DirectInvitationUITestCase: XCTestCase {
    var app: XCUIApplication!
    var server = ""
    let run = String(Int.random(in: 100_000...999_999))
    /// The app's development identity and the address it can be found by.
    var appUser: String { "riley-\(run)" }
    var appEmail: String { "\(appUser)@squareup.test" }

    func launch(as user: String) throws {
        continueAfterFailure = false
        guard let server = ProcessInfo.processInfo.environment["SQUAREUP_TEST_SERVER"] else {
            throw XCTSkip("Set SQUAREUP_TEST_SERVER to run against a development server")
        }
        self.server = server
        app = XCUIApplication()
        app.launchArguments = [
            "-SUUITesting", "-SUInMemoryStore", "-SUReferenceDate", "812030400", "-allowOnDeviceAI", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SUSharedRoomsServer", server, "-SUDevUserID", user,
        ]
        app.launch()
    }

    // MARK: - Steps

    func createSharedGroup(_ name: String) {
        openTab("Groups")
        tap("groups.new", inScrollContent: false)
        let shared = app.segmentedControls["groupEditor.location"].buttons["Shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        shared.tap()
        let field = app.textFields["groupEditor.name"]
        field.tap()
        field.typeText(name)
        tap("groupEditor.save", inScrollContent: false)
        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 20), "Opens the new shared group")
    }

    /// From People: opens "Find a person" and looks up `email`.
    func find(_ email: String) {
        let field = app.textFields["findPerson.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Find a person is open")
        field.tap()
        // A tap can land the cursor mid-text, and Delete removes only what's before it: tap at the
        // end and delete until nothing (but the placeholder) is left.
        for _ in 0..<4 {
            guard let current = field.value as? String, !current.isEmpty, current != "Their email address" else { break }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        XCTAssertEqual(field.value as? String, "Their email address", "the field is empty before typing")
        field.typeText(email)
        tap("findPerson.search", inScrollContent: false)
    }

    func setName(_ name: String) {
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

    /// Groups, pulled to refresh until `identifier` shows up (the app also refreshes on its own).
    func waitInGroups(for identifier: String, timeout: TimeInterval = 60) -> Bool {
        openTab("Groups")
        let target = element(identifier)
        let deadline = Date.now.addingTimeInterval(timeout)
        while !target.exists && Date.now < deadline {
            app.swipeDown()
            _ = target.waitForExistence(timeout: 4)
        }
        return target.exists
    }

    // MARK: - Other people, over HTTP as development accounts

    @discardableResult
    func request(_ method: String, _ path: String, as uid: String, body: [String: Any]? = nil) throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        request.setValue("Dev \(uid)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        final class Box: @unchecked Sendable {
            var status = 0
            var data = Data()
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.data = data ?? Data()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return (box.status, (try? JSONSerialization.jsonObject(with: box.data)) as? [String: Any] ?? [:])
    }

    /// A development account with a name, so it can be found.
    func person(_ uid: String, named name: String) throws {
        XCTAssertEqual(try request("PUT", "/v1/account/profile", as: uid, body: ["displayName": name, "locale": "en_US"]).status, 200)
    }

    /// `uid` creates a shared group and invites the app's account by its address. Returns the group ID.
    @discardableResult
    func groupInvitingTheApp(by uid: String, named name: String) throws -> String {
        let groupID = UUID().uuidString.lowercased()
        let created = try request("POST", "/v1/groups", as: uid, body: ["groupId": groupID, "name": name, "symbol": "fork.knife", "currency": "USD"])
        XCTAssertEqual(created.status, 201)
        let sent = try request("POST", "/v1/groups/\(groupID)/direct-invitations", as: uid, body: ["email": appEmail])
        XCTAssertEqual(sent.status, 201, "\(sent.json)")
        return groupID
    }

    // MARK: - Helpers

    func openTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        for _ in 0..<8 where !button.isHittable { app.swipeDown() }
        button.tap()
    }

    func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func tap(_ identifier: String, timeout: TimeInterval = 15, inScrollContent: Bool = true) {
        let target = element(identifier)
        if !target.waitForExistence(timeout: timeout) { screenshot("missing-\(identifier)") }
        XCTAssertTrue(target.exists, "Missing \(identifier)")
        if inScrollContent, !target.isHittable {
            for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        }
        target.tap()
    }

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// One simulator: the app finds and invites people, and answers invitations people send it.
final class DirectInvitationUITests: DirectInvitationUITestCase {
    override func setUp() async throws {
        try launch(as: appUser)
    }

    /// Riley finds Maya by email, invites her, can't invite her twice, and sees her join once she
    /// accepts (over HTTP). Nobody matches an unknown address, and Riley's own address is "you".
    func testFindAPersonByEmailInviteThemAndSeeThemJoin() throws {
        setName("Riley")
        let maya = "maya-\(run)"
        try person(maya, named: "Maya")
        createSharedGroup("Lake House \(run)")
        tap("group.people", inScrollContent: false)
        tap("sharedGroup.findPerson")
        XCTAssertTrue(app.segmentedControls["groupInvite.mode"].waitForExistence(timeout: 10), "the owner can switch to a link")
        XCTAssertFalse(element("groupInvite.code").exists, "no link is made unless asked for")

        find("nobody-\(run)@squareup.test")
        XCTAssertTrue(element("findPerson.noMatch").waitForExistence(timeout: 20), "the same neutral answer for anyone who can't be invited")

        find("\(maya)@squareup.test")
        XCTAssertTrue(element("findPerson.match").waitForExistence(timeout: 20))
        XCTAssertTrue(labelContaining("Maya").exists && labelContaining("m•••@squareup.test").exists, "name and masked address only")
        screenshot("found")
        tap("findPerson.invite", inScrollContent: false)
        XCTAssertTrue(element("findPerson.sent").waitForExistence(timeout: 20), "sent, waiting for her")
        XCTAssertTrue(element("findPerson.sentRow.Maya").waitForExistence(timeout: 20))
        XCTAssertTrue(labelContaining("Waiting for an answer").exists)
        screenshot("sent")

        find("\(maya)@squareup.test")
        XCTAssertTrue(labelContaining("They already have an invitation to this group").waitForExistence(timeout: 20), "no second invitation")
        XCTAssertFalse(element("findPerson.invite").exists)
        find(appEmail)
        XCTAssertTrue(labelContaining("That's you").waitForExistence(timeout: 20))
        tap("groupInvite.done", inScrollContent: false)
        XCTAssertFalse(element("sharedGroup.person.Maya").exists, "not in the group until she accepts")

        // Maya accepts in her own app (here, over HTTP).
        let waiting = try request("GET", "/v1/account/invitations", as: maya).json["invitations"] as? [[String: Any]] ?? []
        XCTAssertEqual(waiting.first?["inviterName"] as? String, "Riley")
        let invitationID = try XCTUnwrap(waiting.first?["invitationId"] as? String)
        XCTAssertEqual(try request("POST", "/v1/account/invitations/\(invitationID)/accept", as: maya, body: [:]).status, 201)
        XCTAssertTrue(element("sharedGroup.person.Maya").waitForExistence(timeout: 60), "Maya appears once she accepts")
        XCTAssertTrue(labelContaining("2 of 25 people").waitForExistence(timeout: 30))
        screenshot("joined")

        tap("sharedGroup.findPerson")
        find("\(maya)@squareup.test")
        XCTAssertTrue(labelContaining("They're already in this group").waitForExistence(timeout: 20))
    }

    /// Maya and Sam each invite Riley to a group. Both wait at the top of Groups; Riley declines
    /// Sam's (Sam sees it declined) and accepts Maya's, which opens the group with Maya in it.
    func testInvitationsWaitInGroupsUntilAcceptedOrDeclined() throws {
        setName("Riley")
        let maya = "maya-\(run)", sam = "sam-\(run)"
        try person(maya, named: "Maya")
        try person(sam, named: "Sam")
        let dinner = "Dinner \(run)", ski = "Ski \(run)"
        let dinnerID = try groupInvitingTheApp(by: maya, named: dinner)
        let skiID = try groupInvitingTheApp(by: sam, named: ski)

        XCTAssertTrue(waitInGroups(for: "receivedInvitation.\(dinner)"), "the invitation waits in Groups")
        XCTAssertTrue(element("receivedInvitation.\(ski)").exists)
        XCTAssertTrue(labelContaining("Maya invited you to \(dinner)").exists)
        XCTAssertFalse(element("groups.row.\(dinner)").exists, "not a group of Riley's until accepted")
        screenshot("waiting")

        element("receivedInvitation.\(ski)").buttons["receivedInvitation.decline"].tap()
        let confirm = app.buttons["receivedInvitation.confirmDecline"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "declining asks first")
        confirm.tap()
        XCTAssertTrue(element("receivedInvitation.\(ski)").waitForNonExistence(timeout: 20))
        let samSees = try request("GET", "/v1/groups/\(skiID)/direct-invitations", as: sam).json["invitations"] as? [[String: Any]]
        XCTAssertEqual(samSees?.first?["status"] as? String, "declined")

        element("receivedInvitation.\(dinner)").buttons["receivedInvitation.accept"].tap()
        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 30), "accepting opens the group")
        XCTAssertTrue(labelContaining("Maya").waitForExistence(timeout: 20))
        screenshot("accepted")
        let members = try request("GET", "/v1/groups/\(dinnerID)", as: maya).json["snapshot"] as? [String: Any]
        XCTAssertEqual((members?["members"] as? [[String: Any]])?.compactMap { $0["displayName"] as? String }.sorted(), ["Maya", "Riley"])

        openTab("Groups")
        openTab("Groups") // pops to the list
        XCTAssertTrue(element("groups.row.\(dinner)").waitForExistence(timeout: 30), "now one of Riley's shared groups")
        XCTAssertFalse(element("receivedInvitation.\(dinner)").exists)
    }
}

/// Two simulators, two accounts, one development server: Riley (device 1) finds Maya by email and
/// invites her; Maya (device 2) sees the invitation in Groups and accepts; Riley sees her join and
/// adds an expense; Maya sees it and owes her half. Run both at once (see `SharedGroupUITests`);
/// they coordinate through files in `SQUAREUP_TWO_DEVICE_DIR`.
final class DirectInvitationTwoDeviceUITests: DirectInvitationUITestCase {
    private var handoff: URL!

    override func setUp() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SQUAREUP_TWO_DEVICE_DIR"] else {
            throw XCTSkip("Two-account test: set SQUAREUP_TEST_SERVER and SQUAREUP_TWO_DEVICE_DIR")
        }
        handoff = URL(filePath: directory)
        try launch(as: name.contains("MayaAccepts") ? "maya-\(run)" : appUser)
    }

    // MARK: Riley (device 1)

    func testDirectInvitationRileyFindsMayaAndSeesHerJoin() throws {
        setName("Riley")
        let groupName = "Direct \(run)"
        createSharedGroup(groupName)
        signal("direct-name", groupName)
        let mayaEmail = try waitFor("direct-maya", timeout: 300)
        tap("group.people", inScrollContent: false)
        tap("sharedGroup.findPerson")
        find(mayaEmail)
        XCTAssertTrue(element("findPerson.match").waitForExistence(timeout: 20), "Maya can be found by her address")
        tap("findPerson.invite", inScrollContent: false)
        XCTAssertTrue(element("findPerson.sent").waitForExistence(timeout: 20))
        screenshot("riley-sent")
        signal("direct-invited")
        tap("groupInvite.done", inScrollContent: false)

        try waitFor("direct-joined", timeout: 300)
        XCTAssertTrue(element("sharedGroup.person.Maya").waitForExistence(timeout: 60), "Maya appears on Riley's iPhone")
        screenshot("riley-sees-maya")
        app.buttons["Done"].firstMatch.tap()

        // $30.00 for pizza, split equally.
        tap("group.addExpense", inScrollContent: false)
        XCTAssertTrue(app.buttons["3"].waitForExistence(timeout: 10))
        app.buttons["3"].tap()
        app.buttons["0"].tap()
        let title = app.textFields["compose.title"]
        title.tap()
        title.typeText("Pizza\n")
        tap("compose.next", inScrollContent: false)
        tap("compose.review", inScrollContent: false)
        XCTAssertTrue(labelContaining("$15.00 each").waitForExistence(timeout: 10))
        tap("compose.save", inScrollContent: false)
        XCTAssertTrue(labelContaining("Pizza").waitForExistence(timeout: 20))
        signal("direct-expense")
        try waitFor("direct-done", timeout: 300)
    }

    // MARK: Maya (device 2)

    func testDirectInvitationMayaAcceptsInGroups() throws {
        setName("Maya")
        signal("direct-maya", "maya-\(run)@squareup.test")
        let groupName = try waitFor("direct-name", timeout: 300)
        try waitFor("direct-invited", timeout: 300)
        XCTAssertTrue(waitInGroups(for: "receivedInvitation.\(groupName)", timeout: 90), "Riley's invitation reaches Maya's Groups tab")
        XCTAssertTrue(labelContaining("Riley invited you to \(groupName)").exists)
        screenshot("maya-invitation")
        element("receivedInvitation.\(groupName)").buttons["receivedInvitation.accept"].tap()
        XCTAssertTrue(element("group.sharedPeople").waitForExistence(timeout: 30), "accepting opens the group")
        signal("direct-joined")

        try waitFor("direct-expense", timeout: 300)
        XCTAssertTrue(labelContaining("Pizza").waitForExistence(timeout: 60), "Riley's expense reaches Maya")
        XCTAssertTrue(labelContaining("Riley paid $30.00").waitForExistence(timeout: 30))
        XCTAssertTrue(labelContaining("you borrowed").exists, "and her half of it")
        screenshot("maya-sees-expense")
        signal("direct-done")
    }

    // MARK: Hand-off files

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
}
