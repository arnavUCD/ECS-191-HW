import Foundation
import Security

/// Where the App Clip's rooms live: the same server as the full app, read from the same build
/// settings (`Config/Remote.xcconfig`), so the clip and the app always agree on links and codes.
struct ClipConfiguration: Sendable, Equatable {
    let baseURL: URL

    static func fromBundle(_ info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> ClipConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
            return raw
        }
        guard let host = value("SquareUpAPIHost"), let url = URL(string: "\(value("SquareUpAPIScheme") ?? "https")://\(host)"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        #if !DEBUG
        // Release builds talk to a real server only over HTTPS.
        guard scheme == "https" else { return nil }
        #endif
        return ClipConfiguration(baseURL: url)
    }

    /// The build's server — or, DEBUG only, `-SUClipServer <origin>`: a development server for local
    /// tests, like the full app's `-SUSharedRoomsServer` (e.g. `http://127.0.0.1:8080`).
    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> ClipConfiguration? {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-SUClipServer"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]), url.host() != nil {
            return ClipConfiguration(baseURL: url)
        }
        #endif
        return fromBundle()
    }

    /// DEBUG only: `-SUClipOpen <link or code>` opens an invitation at launch the way an App Clip
    /// invocation would. Real invocations arrive as a browsing-web user activity (`SquareUpClipApp`).
    static func launchInvitation(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-SUClipOpen"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        #endif
        return nil
    }

    /// The invitation an invocation URL (or something pasted) carries, read exactly like the full app.
    func invitation(in text: String) -> InvitationInput? {
        InvitationInput.parse(text, expectedHost: baseURL.host(), expectedPort: baseURL.port)
    }

    /// This server's invitation prefix itself (`https://<server>/r/`, or just the origin): the URL an
    /// App Clip experience or TestFlight invocation is registered with. It names no room, so the
    /// clip stays where it is (the code entry, or the room it returned to).
    func isInvitationPrefix(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return InvitationLink.isPrefix(url, expectedHost: baseURL.host(), expectedPort: baseURL.port)
    }
}

/// A failure talking to the server, with the server's stable code when it refused.
struct ClipError: Error, Equatable, Sendable {
    let code: String
    let message: String
    let room: RoomDTO?

    static let offline = ClipError(code: "offline", message: String(localized: "You're offline. Check your connection and try again."), room: nil)
    static let unexpected = ClipError(code: "unexpected", message: String(localized: "Something went wrong. Try again."), room: nil)

    /// The guest's access to this room ended (expired credential, removed, room gone).
    var endsAccess: Bool {
        ["credential_expired", "not_a_participant", "room_not_found", "invitation_expired", "invitation_revoked", "invitation_invalid"].contains(code)
    }
}

/// The guest side of `/v1` for temporary rooms (server/API.md): preview and join by link or code,
/// read the room, send changes, and see the payer's payment methods once something is owed. Uses
/// only the room-scoped guest credential: never an account, groups, or receipt intelligence.
/// Nothing is logged — URLs and bodies carry invitation secrets and receipt contents.
struct ClipRoomClient: Sendable {
    let configuration: ClipConfiguration
    var session: URLSession = .shared

    /// With a guest credential, the preview says whether that guest is already in this room
    /// (`youAreParticipantId`).
    func preview(_ invitation: InvitationInput, credential: String?) async throws(ClipError) -> InvitationPreviewDTO {
        let response: InvitationPreviewResponse
        switch invitation {
        case .token(let token): response = try await send("GET", ["v1", "receipt-room-invitations", token], credential: credential)
        case .code(let code):
            response = try await send("POST", ["v1", "receipt-room-codes", "preview"], body: CodeRequest(code: code), credential: credential)
        }
        return response.invitation
    }

    /// Joins with a display name, or returns to the same participant with the credential from before.
    func join(_ invitation: InvitationInput, name: String?, credential: String?) async throws(ClipError) -> JoinResponse {
        switch invitation {
        case .token(let token):
            try await send("POST", ["v1", "receipt-room-invitations", token, "join"], body: JoinRequest(displayName: name), credential: credential)
        case .code(let code):
            try await send("POST", ["v1", "receipt-room-codes", "join"], body: CodeRequest(code: code, displayName: name), credential: credential)
        }
    }

    func room(_ roomID: String, credential: String) async throws(ClipError) -> RoomDTO {
        let response: RoomResponse = try await send("GET", ["v1", "receipt-rooms", roomID], credential: credential)
        return response.room
    }

    func command(_ envelope: CommandEnvelope, room roomID: String, credential: String) async throws(ClipError) -> CommandResponse {
        try await send("POST", ["v1", "receipt-rooms", roomID, envelope.type == "finalize" ? "finalize" : "commands"], body: envelope, credential: credential)
    }

    func paymentDestinations(room roomID: String, credential: String) async throws(ClipError) -> RoomDestinationsDTO {
        try await send("GET", ["v1", "receipt-rooms", roomID, "payment-destinations"], credential: credential)
    }

    private func send<Response: Decodable>(_ method: String, _ path: [String], credential: String?) async throws(ClipError) -> Response {
        try await send(method, path, body: JSONValue?.none, credential: credential)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: [String], body: Body?, credential: String?)
        async throws(ClipError) -> Response {
        var url = configuration.baseURL
        for component in path { url.append(path: component, directoryHint: .notDirectory) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        if let credential { request.setValue("Guest \(credential)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .offline
        }
        guard let http = response as? HTTPURLResponse else { throw .unexpected }
        if (200..<300).contains(http.statusCode) {
            do { return try JSONDecoder().decode(Response.self, from: data) } catch { throw .unexpected }
        }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { throw .unexpected }
        throw ClipError(code: envelope.error.code, message: envelope.error.message, room: envelope.room)
    }
}

/// The guest credential for each room this App Clip joined, in the Keychain (this device only).
///
/// When the full app is installed it could adopt the guest's place with the same credential
/// (`/link-guest`). That handoff needs an App Group shared by both targets and isn't set up (see
/// `HW/App/APP_CLIP_ACTIVATION.md`), so the clip keeps its credentials alone.
struct ClipCredentials: Sendable {
    let service = "edu.ucdavis.ecs191.SquareUp.Clip.credentials"

    func credential(for roomID: String) -> String? {
        var query = base(roomID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ credential: String, for roomID: String) {
        SecItemDelete(base(roomID) as CFDictionary)
        var item = base(roomID)
        item[kSecValueData as String] = Data(credential.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(_ roomID: String) {
        SecItemDelete(base(roomID) as CFDictionary)
    }

    /// The most recent room joined from this App Clip (so reopening it returns there).
    var lastRoomID: String? {
        get { UserDefaults.standard.string(forKey: "clip.lastRoomID") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "clip.lastRoomID") }
    }

    private func base(_ roomID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: roomID]
    }
}
