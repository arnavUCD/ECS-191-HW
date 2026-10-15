import Foundation
import OSLog

/// Who is calling: the full-app account, a room-scoped guest credential (App Clip), or nobody
/// (invitation preview).
nonisolated enum RemoteCaller: Sendable, Equatable {
    case account
    case guest(String)
    case anonymous
}

/// A failure talking to the server, with enough structure to explain it and recover.
nonisolated enum RemoteError: Error, Equatable, Sendable {
    /// This build has no server configured.
    case notConfigured
    /// The request never reached the server (or the response never came back).
    case offline
    case timedOut
    /// The server refused with a stable code (server/API.md "Errors").
    case server(ServerRefusal)
    case account(AccountSession.Failure)
    /// An unexpected status or body. Nothing about it is shown to people.
    case unexpected(status: Int)

    var refusal: ServerRefusal? { if case .server(let refusal) = self { refusal } else { nil } }
    var code: String? { refusal?.code }

    /// Whether the outcome is unknown, so the same request (same idempotency key) may be resent.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut: true
        case .server(let refusal): refusal.status == 503 || refusal.status == 429
        case .unexpected(let status): status >= 500
        case .notConfigured, .account: false
        }
    }
}

nonisolated struct ServerRefusal: Equatable, Sendable {
    let status: Int
    let code: String
    let message: String
    let currentRevision: Int?
    let retryAfterSeconds: Int?
    /// The current snapshot, when the caller may see it (revision conflicts, terminal rooms).
    let room: RoomDTO?
    // Milestone 7 (shared groups): details that let the app explain and recover.
    /// The group's event cursor at the time of a revision conflict.
    var cursor: Int?
    /// What the payer owes now, when a payment amount was refused.
    var owed: Int?
    /// A machine-readable reason (e.g. `allocationsDoNotReconcile`, `legacyOrganization`).
    var reason: String?
    /// Payments waiting for confirmation that block a change.
    var attemptIds: [String]?
    /// Unit claims: how many of the line are still unclaimed.
    var available: Int?
    /// People who haven't reviewed their share.
    var participantIds: [String]?
}

/// The `/v1` API (server/API.md). Stateless apart from the account session it asks for tokens.
///
/// Logging is limited to method, route template, status, error code, and duration — never
/// URLs (they contain tokens and room IDs), bodies, or headers.
nonisolated struct RoomAPIClient: Sendable {
    let configuration: RemoteConfiguration
    let transport: any HTTPTransport
    let account: AccountSession

    // MARK: Rooms

    func publish(_ body: PublishRequest) async throws(RemoteError) -> PublishResponse {
        try await send("POST", ["v1", "receipt-rooms"], route: "publish", body: body, as: .account)
    }

    func room(_ id: String, as caller: RemoteCaller) async throws(RemoteError) -> RoomDTO {
        let response: RoomResponse = try await send("GET", ["v1", "receipt-rooms", id], route: "room", as: caller)
        return response.room
    }

    func command(_ envelope: CommandEnvelope, room id: String, as caller: RemoteCaller) async throws(RemoteError) -> CommandResponse {
        let path = envelope.type == "finalize" ? "finalize" : "commands"
        return try await send("POST", ["v1", "receipt-rooms", id, path], route: path, body: envelope, as: caller)
    }

    // MARK: Invitations

    func createInvitation(room id: String, options: InvitationOptions) async throws(RemoteError) -> InvitationDTO {
        let response: InvitationResponse = try await send("POST", ["v1", "receipt-rooms", id, "invitations"], route: "createInvitation",
                                                          body: options, as: .account)
        return response.invitation
    }

    func invitations(room id: String) async throws(RemoteError) -> [InvitationDTO] {
        let response: InvitationListResponse = try await send("GET", ["v1", "receipt-rooms", id, "invitations"], route: "invitations",
                                                              as: .account)
        return response.invitations
    }

    func revokeInvitation(_ invitationID: String, room id: String) async throws(RemoteError) -> InvitationDTO {
        let response: InvitationResponse = try await send("DELETE", ["v1", "receipt-rooms", id, "invitations", invitationID],
                                                          route: "revokeInvitation", as: .account)
        return response.invitation
    }

    func preview(token: String, as caller: RemoteCaller) async throws(RemoteError) -> InvitationPreviewDTO {
        let response: InvitationPreviewResponse = try await send("GET", ["v1", "receipt-room-invitations", token], route: "preview",
                                                                 as: caller)
        return response.invitation
    }

    func join(token: String, _ body: JoinRequest, as caller: RemoteCaller) async throws(RemoteError) -> JoinResponse {
        try await send("POST", ["v1", "receipt-room-invitations", token, "join"], route: "join", body: body, as: caller)
    }

    /// A short code typed by someone (in the body, never the path), previewed like a link.
    func preview(code: String, as caller: RemoteCaller) async throws(RemoteError) -> InvitationPreviewDTO {
        let response: InvitationPreviewResponse = try await send("POST", ["v1", "receipt-room-codes", "preview"], route: "previewCode",
                                                                 body: CodeRequest(code: code), as: caller)
        return response.invitation
    }

    func join(code: String, _ body: JoinRequest, as caller: RemoteCaller) async throws(RemoteError) -> JoinResponse {
        try await send("POST", ["v1", "receipt-room-codes", "join"], route: "joinCode",
                       body: CodeRequest(code: code, displayName: body.displayName, seatId: body.seatId), as: caller)
    }

    /// Temporary rooms: the payer's chosen payment methods, only while the caller owes them.
    func paymentDestinations(room id: String, as caller: RemoteCaller) async throws(RemoteError) -> RoomDestinationsDTO {
        try await send("GET", ["v1", "receipt-rooms", id, "payment-destinations"], route: "paymentDestinations", as: caller)
    }

    func linkGuest(room id: String, guestCredential: String) async throws(RemoteError) -> RoomDTO {
        let response: RoomResponse = try await send("POST", ["v1", "receipt-rooms", id, "link-guest"], route: "linkGuest",
                                                    body: LinkGuestRequest(guestToken: guestCredential), as: .account)
        return response.room
    }

    // MARK: Transport

    func send<Response: Decodable>(_ method: String, _ path: [String], query: [String: String] = [:], route: String, as caller: RemoteCaller)
        async throws(RemoteError) -> Response {
        try await send(method, path, query: query, route: route, body: JSONValue?.none, as: caller)
    }

    func send<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: [String], query: [String: String] = [:], route: String, body: Body?, as caller: RemoteCaller
    ) async throws(RemoteError) -> Response {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let requestID = UUID().uuidString.lowercased()
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw .unexpected(status: 0)
            }
        }
        let (data, status) = try await perform(request, method: method, route: route, requestID: requestID, as: caller)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            Log.sync.error("\(route, privacy: .public): unreadable response (\(String(describing: type(of: error)), privacy: .public))")
            throw .unexpected(status: status)
        }
    }

    // MARK: Receipt photos (shared only when the host chooses to)

    /// Uploads one receipt photo (JPEG) to a room the caller hosts. The server strips metadata and
    /// keeps it in a private bucket, served only to people in the room.
    func uploadReceiptPhoto(_ jpeg: Data, room id: String) async throws(RemoteError) -> AssetUploadDTO {
        var request = URLRequest(url: url(["v1", "receipt-rooms", id, "receipt-assets"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let requestID = UUID().uuidString.lowercased()
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        request.httpBody = jpeg
        let (data, status) = try await perform(request, method: "POST", route: "uploadAsset", requestID: requestID, as: .account)
        do {
            return try Self.decoder.decode(AssetUploadDTO.self, from: data)
        } catch {
            throw .unexpected(status: status)
        }
    }

    /// A shared receipt photo, for someone in the room (never cached by URL: it isn't public).
    func receiptPhoto(_ assetID: String, room id: String, as caller: RemoteCaller) async throws(RemoteError) -> Data {
        var request = URLRequest(url: url(["v1", "receipt-rooms", id, "receipt-assets", assetID]))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let requestID = UUID().uuidString.lowercased()
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        return try await perform(request, method: "GET", route: "asset", requestID: requestID, as: caller).data
    }

    /// Authorizes, sends, refreshes an expired ID token once, and turns refusals into `RemoteError`.
    /// Returns the body of a 2xx response.
    private func perform(_ original: URLRequest, method: String, route: String, requestID: String, as caller: RemoteCaller)
        async throws(RemoteError) -> (data: Data, status: Int) {
        var request = original
        let started = ContinuousClock.now
        var refreshed = false
        while true {
            try await authorize(&request, caller, forceRefresh: refreshed)
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                Log.sync.notice("\(method, privacy: .public) \(route, privacy: .public) failed to reach the server")
                if TransportFailure.isTimeout(error) { throw .timedOut }
                throw .offline
            }
            let elapsed = started.duration(to: .now)
            if (200..<300).contains(response.statusCode) {
                Log.sync.debug("\(method, privacy: .public) \(route, privacy: .public) \(response.statusCode, privacy: .public) in \(elapsed, privacy: .public)")
                return (data, response.statusCode)
            }
            let envelope = try? Self.decoder.decode(ErrorEnvelope.self, from: data)
            Log.sync.notice("""
            \(method, privacy: .public) \(route, privacy: .public) \(response.statusCode, privacy: .public) \
            \(envelope?.error.code ?? "-", privacy: .public) request \(envelope?.error.requestId ?? requestID, privacy: .public)
            """)
            // An expired Firebase ID token: refresh once and retry.
            if response.statusCode == 401, caller == .account, !refreshed, envelope?.error.code == "unauthenticated" {
                refreshed = true
                continue
            }
            guard let envelope else { throw .unexpected(status: response.statusCode) }
            throw .server(ServerRefusal(
                status: response.statusCode, code: envelope.error.code, message: envelope.error.message,
                currentRevision: envelope.error.currentRevision,
                retryAfterSeconds: envelope.error.retryAfterSeconds ?? Int(response.value(forHTTPHeaderField: "Retry-After") ?? ""),
                room: envelope.room, cursor: envelope.error.cursor, owed: envelope.error.owed, reason: envelope.error.reason,
                attemptIds: envelope.error.attemptIds, available: envelope.error.available, participantIds: envelope.error.participantIds
            ))
        }
    }

    private func authorize(_ request: inout URLRequest, _ caller: RemoteCaller, forceRefresh: Bool) async throws(RemoteError) {
        switch caller {
        case .anonymous:
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        case .guest(let credential):
            request.setValue("Guest \(credential)", forHTTPHeaderField: "Authorization")
        case .account:
            do {
                await request.setValue(try account.authorizationHeader(forceRefresh: forceRefresh), forHTTPHeaderField: "Authorization")
            } catch let failure as AccountSession.Failure {
                throw failure == .offline ? .offline : .account(failure)
            } catch {
                throw .account(.unavailable)
            }
        }
    }

    private func url(_ path: [String], query: [String: String] = [:]) -> URL {
        var url = configuration.baseURL
        for component in path { url.append(path: component, directoryHint: .notDirectory) }
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        return url
    }

    private static let decoder = JSONDecoder()
}
