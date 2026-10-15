import XCTest

/// The App Clip (prepared, not activated — `HW/App/APP_CLIP_ACTIVATION.md`) against a local
/// development server. The host side of a temporary room ("Split with people now") runs over HTTP
/// from this test with a `Dev` account; the guest side is the installed App Clip, launched by bundle
/// ID with the invitation the way an invocation would open it (`-SUClipOpen`, DEBUG only). A real
/// invocation (QR, App Clip Code, Smart App Banner) needs the paid Apple team and a device.
///
/// Opt-in; skips unless the runner gets `SQUAREUP_TEST_SERVER` (a server with
/// `SQUAREUP_ALLOW_DEV_AUTH=1`) and the clip's DEBUG build is installed on the same simulator
/// (`xcrun simctl install <device> SquareUpClip.app`). See `server/README.md`.
@MainActor
final class AppClipUITests: XCTestCase {
    private var host: DevHost!
    private var server = ""
    private let clipBundleID = "edu.ucdavis.ecs191.SquareUp.Clip"

    override func setUp() async throws {
        continueAfterFailure = false
        guard let origin = ProcessInfo.processInfo.environment["SQUAREUP_TEST_SERVER"], let url = URL(string: origin) else {
            throw XCTSkip("App Clip test: set SQUAREUP_TEST_SERVER")
        }
        server = origin
        host = DevHost(server: url, uid: "clip-host-\(UUID().uuidString.prefix(8).lowercased())")
    }

    /// Join by code, claim (a whole item and some of a counted one), review, see what you owe once
    /// the host finalizes, report the payment, and see "all square" after the host confirms —
    /// then reopen the clip and land back on the read-only summary.
    func testGuestJoinsClaimsPaysAndSeesAllSquare() async throws {
        try await host.startRoom(withDestination: true)
        let invitation = try await host.invite()
        let clip = launchClip(opening: invitation.code)

        XCTAssertTrue(clip.staticTexts["Driftwood Kitchen"].waitForExistence(timeout: 20), "The preview names the receipt before joining")
        XCTAssertFalse(clip.staticTexts["Beer"].exists, "No items or amounts before joining")
        let name = clip.textFields["clip.name"]
        name.tap()
        name.typeText("Maya")
        clip.buttons["clip.join"].tap()

        let fries = clip.descendants(matching: .any)["clip.item.Fries"]
        XCTAssertTrue(fries.waitForExistence(timeout: 20), "Joined: the items appear")
        fries.buttons["Mine"].tap()
        XCTAssertTrue(fries.staticTexts["you"].waitForExistence(timeout: 10), "Claimed by you")

        let beer = clip.descendants(matching: .any)["clip.item.Beer"]
        beer.buttons["Some"].tap()
        let stepper = clip.steppers["clip.units"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons.element(boundBy: stepper.buttons.count - 1).tap() // "+" (the last of the two)
        XCTAssertTrue(clip.staticTexts["2 of 3"].exists || stepper.label.contains("2 of 3"), "Two of the three beers")
        clip.buttons["Save"].tap()
        XCTAssertTrue(beer.staticTexts["you ×2 · 1 left"].waitForExistence(timeout: 10), "Two of three claimed; one left for others")
        attach(clip, "clip-claimed")

        clip.buttons["clip.review"].tap()
        XCTAssertTrue(clip.buttons["Reviewed · tap if something changes"].waitForExistence(timeout: 10))

        // The host takes the last beer and finalizes; the clip picks it up by polling.
        try await host.send("claimUnits", ["itemId": host.beerID, "units": 1])
        try await host.finalize()
        let owed = clip.staticTexts["clip.owed"]
        XCTAssertTrue(owed.waitForExistence(timeout: 30), "The final split arrives without a refresh")
        // Fries 9.00 + two beers 12.00 + tax 2.33 (proportional: 3.00 × 21/27, largest remainder).
        XCTAssertEqual(owed.label, "$23.33")
        XCTAssertTrue(clip.staticTexts["riley-c"].waitForExistence(timeout: 10), "The payer's chosen method, shown because Maya owes")
        attach(clip, "clip-owes")

        clip.buttons["clip.paid"].tap()
        XCTAssertTrue(clip.staticTexts["You reported it · waiting for Riley to confirm"].waitForExistence(timeout: 10))
        try await host.confirm(invitation.guest(of: try host.room()))
        XCTAssertTrue(clip.staticTexts["All square. Everyone's payment is confirmed."].waitForExistence(timeout: 30))
        XCTAssertFalse(clip.staticTexts["riley-c"].exists, "Methods disappear once nothing is owed")
        attach(clip, "clip-all-square")

        // Reopened without an invitation, the clip returns to the same (ended) room.
        clip.terminate()
        let reopened = XCUIApplication(bundleIdentifier: clipBundleID)
        reopened.launchArguments = baseArguments
        reopened.launch()
        XCTAssertTrue(reopened.staticTexts["All square. Everyone's payment is confirmed."].waitForExistence(timeout: 20))
        reopened.terminate()
    }

    /// A turned-off invitation explains itself; typing the host's new code (any case, no dashes)
    /// joins.
    func testRevokedInvitationThenTypedCode() async throws {
        try await host.startRoom(withDestination: false)
        let old = try await host.invite()
        try await host.revoke(old.id)
        let fresh = try await host.invite()
        let clip = launchClip(opening: old.code)

        XCTAssertTrue(clip.staticTexts["The host turned off this invitation. Ask for a new code."].waitForExistence(timeout: 20))
        clip.buttons["clip.enterCode"].tap()
        let code = clip.textFields["clip.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText(fresh.code.replacingOccurrences(of: "-", with: "").lowercased())
        clip.buttons["clip.continue"].tap()
        let name = clip.textFields["clip.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap()
        name.typeText("Dev")
        clip.buttons["clip.join"].tap()
        XCTAssertTrue(clip.descendants(matching: .any)["clip.item.Fries"].waitForExistence(timeout: 20))
        attach(clip, "clip-joined-by-code")

        // The host cancels: the room ends for the guest.
        try await host.send("cancel", [:])
        XCTAssertTrue(clip.staticTexts["The host closed this room."].waitForExistence(timeout: 30))
        clip.terminate()
    }

    // MARK: - Helpers

    private var baseArguments: [String] {
        ["-SUClipServer", server, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func launchClip(opening invitation: String) -> XCUIApplication {
        let clip = XCUIApplication(bundleIdentifier: clipBundleID)
        clip.terminate()
        clip.launchArguments = baseArguments + ["-SUClipOpen", invitation]
        clip.launch()
        return clip
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The host of a temporary room, over HTTP with a development account (`Authorization: Dev <uid>`).
/// Invitation tokens and codes stay in memory; nothing is printed.
private final class DevHost: @unchecked Sendable {
    struct Invitation {
        let id: String
        let code: String
        func guest(of room: [String: Any]) -> String {
            let participants = room["participants"] as? [[String: Any]] ?? []
            return participants.first { ($0["kind"] as? String) != "host" }?["id"] as? String ?? ""
        }
    }

    let server: URL
    let uid: String
    let roomID = UUID().uuidString.lowercased()
    let hostID = UUID().uuidString.lowercased()
    let beerID = UUID().uuidString.lowercased()
    let friesID = UUID().uuidString.lowercased()

    init(server: URL, uid: String) {
        self.server = server
        self.uid = uid
    }

    func startRoom(withDestination: Bool) async throws {
        _ = try await request("PUT", "/v1/account/profile", ["displayName": "Riley", "locale": "en_US"])
        var destinations: [String] = []
        if withDestination {
            let id = UUID().uuidString.lowercased()
            _ = try await request("PUT", "/v1/account/destinations/\(id)", [
                "provider": "venmo", "value": ["kind": "username", "value": "riley-c"], "isEnabled": true, "isPreferred": true,
            ])
            destinations = [id]
        }
        _ = try await request("POST", "/v1/receipt-rooms", [
            "kind": "temporary", "roomId": roomID, "hostParticipantId": hostID, "payerId": hostID,
            "participants": [["id": hostID, "displayName": "Riley"]],
            "paymentDestinationIds": destinations,
            "receipt": [
                "merchant": "Driftwood Kitchen", "date": "2026-09-24", "currency": "USD", "total": 3000,
                "items": [
                    ["id": beerID, "name": "Beer", "lineTotal": 1800, "quantity": 3, "unitPrice": 600],
                    ["id": friesID, "name": "Fries", "lineTotal": 900],
                ],
                "charges": [["id": UUID().uuidString.lowercased(), "kind": "tax", "label": "Tax", "amount": 300]],
            ],
        ])
    }

    func invite() async throws -> Invitation {
        let body = try await request("POST", "/v1/receipt-rooms/\(roomID)/invitations", [:])
        let invitation = try XCTUnwrap(body["invitation"] as? [String: Any])
        return Invitation(id: try XCTUnwrap(invitation["invitationId"] as? String), code: try XCTUnwrap(invitation["code"] as? String))
    }

    func revoke(_ invitationID: String) async throws {
        _ = try await request("DELETE", "/v1/receipt-rooms/\(roomID)/invitations/\(invitationID)", nil)
    }

    func room() async throws -> [String: Any] {
        let body = try await request("GET", "/v1/receipt-rooms/\(roomID)", nil)
        return try XCTUnwrap(body["room"] as? [String: Any])
    }

    func send(_ type: String, _ payload: [String: Any], path: String = "commands") async throws {
        let current = try await room()
        let revision = try XCTUnwrap(current["revision"] as? Int)
        _ = try await request("POST", "/v1/receipt-rooms/\(roomID)/\(path)", [
            "commandId": UUID().uuidString.lowercased(), "idempotencyKey": UUID().uuidString.lowercased(),
            "expectedRevision": revision, "type": type, "payload": payload,
        ])
    }

    /// Final review, then finalize — acknowledging anyone whose share changed after they reviewed.
    func finalize() async throws {
        try await send("transition", ["move": "requestFinalReview"])
        let unreviewed = try await room()["unreviewed"] as? [String] ?? []
        try await send("finalize", ["acknowledgeUnreviewed": unreviewed], path: "finalize")
    }

    func confirm(_ participantID: String) async throws {
        try await send("confirmPayment", ["participantId": participantID])
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.setValue("Dev \(uid)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            // Only the stable error code, never the body (it can carry receipt contents).
            let code = (json["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            throw NSError(domain: "DevHost", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path.split(separator: "/").prefix(3).joined(separator: "/")) → \(status) \(code)"])
        }
        return json
    }
}
