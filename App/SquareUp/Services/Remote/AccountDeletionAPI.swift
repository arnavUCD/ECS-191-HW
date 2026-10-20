import Foundation

/// Deleting an account (`/v1/account`, server `services/account_deletion.py`): what deleting would
/// do now and what has to happen first, then the deletion itself, which needs a sign-in from the
/// last few minutes (`AccountSession.reauthenticate`). The Firebase sign-in is deleted afterwards.
nonisolated struct AccountDeletionAPI: Sendable {
    let client: RoomAPIClient

    init(configuration: RemoteConfiguration, transport: any HTTPTransport, account: AccountSession) {
        client = RoomAPIClient(configuration: configuration, transport: transport, account: account)
    }

    func plan() async throws(RemoteError) -> AccountDeletionPlan {
        let response: AccountDeletionPlanResponse = try await client.send("GET", ["v1", "account", "deletion"], route: "accountDeletionCheck",
                                                                          as: .account)
        return response.deletion
    }

    func delete() async throws(RemoteError) {
        let _: AccountDeletedResponse = try await client.send("DELETE", ["v1", "account"], route: "accountDelete", as: .account)
    }
}

/// What deleting the account would do now. Empty `blockers` means it can go ahead.
nonisolated struct AccountDeletionPlan: Codable, Equatable, Sendable {
    let blockers: [Blocker]
    /// Groups nobody else joined: deleted with the account.
    let groupsDeleted: [GroupReference]
    /// Groups other people are in: the person leaves, and their name stays on what they shared.
    let groupsLeft: [GroupReference]
    /// Live rooms the person hosted that have ended: deleted, with their receipt photos.
    let roomsDeleted: Int

    nonisolated struct GroupReference: Codable, Equatable, Sendable, Identifiable {
        let groupId: String
        let name: String
        var id: String { groupId }
    }

    /// Something to finish first, in a group or a live room.
    nonisolated struct Blocker: Codable, Equatable, Sendable {
        /// `groupBalance`, `groupPayment`, `groupReceipt`, `groupOwner`, `roomHosted`, `roomJoined`,
        /// `roomOwed` (anything else is explained generally).
        let kind: String
        let groupId: String?
        let roomId: String?
        let name: String
        /// The person's balance in the group, in minor units (negative: they owe).
        let balance: Int?
        let currency: String?
    }
}

private nonisolated struct AccountDeletionPlanResponse: Codable, Sendable {
    let deletion: AccountDeletionPlan
}

private nonisolated struct AccountDeletedResponse: Codable, Sendable {
    let deleted: Bool
}
