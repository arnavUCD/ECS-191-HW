import Foundation

/// Demo Mode's endpoints (`/v1/demo`, server/API.md "Demo workspaces"): start this iPhone's own
/// workspace of fictional sample data, reset it to its seed, or leave it. Starting needs no account;
/// the server answers with a demo credential, kept in the Keychain by `AccountSession.adoptDemo`.
nonisolated struct DemoWorkspaceAPI: Sendable {
    let client: RoomAPIClient

    init(configuration: RemoteConfiguration, transport: any HTTPTransport, account: AccountSession) {
        client = RoomAPIClient(configuration: configuration, transport: transport, account: account)
    }

    func start() async throws(RemoteError) -> DemoSessionDTO {
        let response: DemoSessionResponse = try await client.send("POST", ["v1", "demo", "sessions"], route: "demoStart", body: EmptyBody(),
                                                                  as: .anonymous)
        return response.session
    }

    func reset() async throws(RemoteError) -> ProfileDTO {
        let response: DemoResetResponse = try await client.send("POST", ["v1", "demo", "reset"], route: "demoReset", body: EmptyBody(), as: .account)
        return response.profile
    }

    func end() async throws(RemoteError) {
        let _: DemoEndResponse = try await client.send("DELETE", ["v1", "demo", "session"], route: "demoEnd", as: .account)
    }
}

nonisolated struct DemoSessionDTO: Codable, Sendable {
    let token: String
    let userId: String
    let expiresAt: String?
    let profile: ProfileDTO
}

private nonisolated struct EmptyBody: Codable, Sendable {}

private nonisolated struct DemoSessionResponse: Codable, Sendable {
    let session: DemoSessionDTO
}

private nonisolated struct DemoResetResponse: Codable, Sendable {
    let profile: ProfileDTO
}

private nonisolated struct DemoEndResponse: Codable, Sendable {
    let ended: Bool
}
