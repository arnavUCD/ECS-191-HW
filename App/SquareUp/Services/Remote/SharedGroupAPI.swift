import Foundation

/// The milestone 7 `/v1/account` and `/v1/groups` endpoints (server/API.md "Shared groups").
///
/// Uses the same transport as shared rooms (`RoomAPIClient.send`): the account's Firebase ID token
/// (refreshed once on 401), request IDs, and logs limited to method, route template, status, and
/// error code — never URLs (invitation codes), bodies, or headers.
nonisolated struct SharedGroupAPI: Sendable {
    let client: RoomAPIClient

    init(configuration: RemoteConfiguration, transport: any HTTPTransport, account: AccountSession) {
        client = RoomAPIClient(configuration: configuration, transport: transport, account: account)
    }

    var configuration: RemoteConfiguration { client.configuration }

    // MARK: Account and profile

    func account() async throws(RemoteError) -> AccountDTO {
        let response: AccountResponse = try await client.send("GET", ["v1", "account"], route: "account", as: .account)
        return response.account
    }

    func saveProfile(_ request: ProfileRequest) async throws(RemoteError) -> ProfileDTO {
        let response: ProfileResponse = try await client.send("PUT", ["v1", "account", "profile"], route: "profile", body: request, as: .account)
        return response.profile
    }

    func saveDestination(_ id: String, _ request: DestinationRequest) async throws(RemoteError) -> ProfileDTO {
        let response: ProfileResponse = try await client.send("PUT", ["v1", "account", "destinations", id], route: "saveDestination",
                                                              body: request, as: .account)
        return response.profile
    }

    func deleteDestination(_ id: String) async throws(RemoteError) -> ProfileDTO {
        let response: ProfileResponse = try await client.send("DELETE", ["v1", "account", "destinations", id], route: "deleteDestination",
                                                              as: .account)
        return response.profile
    }

    // MARK: Groups

    func groups() async throws(RemoteError) -> [GroupSummaryDTO] {
        let response: GroupListResponse = try await client.send("GET", ["v1", "groups"], route: "groups", as: .account)
        return response.groups
    }

    func createGroup(_ request: CreateGroupRequest) async throws(RemoteError) -> GroupCreateResponse {
        try await client.send("POST", ["v1", "groups"], route: "createGroup", body: request, as: .account)
    }

    func publish(_ request: PublicationRequest) async throws(RemoteError) -> GroupCreateResponse {
        try await client.send("POST", ["v1", "groups", "publications"], route: "publishGroup", body: request, as: .account)
    }

    func snapshot(_ groupID: String) async throws(RemoteError) -> GroupSnapshotDTO {
        let response: GroupSnapshotResponse = try await client.send("GET", ["v1", "groups", groupID], route: "groupSnapshot", as: .account)
        return response.snapshot
    }

    func changes(_ groupID: String, after cursor: Int) async throws(RemoteError) -> GroupChangesDTO {
        let response: GroupChangesResponse = try await client.send("GET", ["v1", "groups", groupID, "changes"], query: ["after": String(cursor)],
                                                                   route: "groupChanges", as: .account)
        return response.changes
    }

    func command(_ envelope: GroupCommandEnvelope, group groupID: String) async throws(RemoteError) -> GroupCommandResponse {
        try await client.send("POST", ["v1", "groups", groupID, "commands"], route: "groupCommand", body: envelope, as: .account)
    }

    /// One receipt posted into the group, as this member may see it.
    func receipt(_ receiptID: String, group groupID: String) async throws(RemoteError) -> GroupReceiptDTO {
        let response: GroupReceiptResponse = try await client.send("GET", ["v1", "groups", groupID, "receipts", receiptID], route: "groupReceipt",
                                                                   as: .account)
        return response.receipt
    }

    func revealDestinations(group groupID: String, member memberID: String) async throws(RemoteError) -> RevealedDestinationsDTO {
        try await client.send("GET", ["v1", "groups", groupID, "members", memberID, "destinations"], route: "revealDestinations", as: .account)
    }

    // MARK: Invitations

    func createInvitation(group groupID: String, seat seatID: String?) async throws(RemoteError) -> GroupInvitationDTO {
        let response: GroupInvitationResponse = try await client.send("POST", ["v1", "groups", groupID, "invitations"], route: "createGroupInvitation",
                                                                      body: GroupInvitationRequest(seatMemberId: seatID), as: .account)
        return response.invitation
    }

    func invitations(group groupID: String) async throws(RemoteError) -> [GroupInvitationDTO] {
        let response: GroupInvitationListResponse = try await client.send("GET", ["v1", "groups", groupID, "invitations"],
                                                                          route: "groupInvitations", as: .account)
        return response.invitations
    }

    func revokeInvitation(_ invitationID: String, group groupID: String) async throws(RemoteError) -> GroupInvitationDTO {
        let response: GroupInvitationResponse = try await client.send("DELETE", ["v1", "groups", groupID, "invitations", invitationID],
                                                                      route: "revokeGroupInvitation", as: .account)
        return response.invitation
    }

    func preview(code: String) async throws(RemoteError) -> GroupInvitationPreviewDTO {
        let response: GroupInvitationPreviewResponse = try await client.send("GET", ["v1", "group-invitations", code], route: "groupInvitationPreview",
                                                                             as: .account)
        return response.invitation
    }

    func accept(code: String, displayName: String) async throws(RemoteError) -> AcceptGroupInvitationResponse {
        try await client.send("POST", ["v1", "group-invitations", code, "accept"], route: "acceptGroupInvitation",
                              body: AcceptGroupInvitationRequest(displayName: displayName), as: .account)
    }

    // MARK: Direct invitations ("Find a person")

    /// The email or phone number goes in the body, never the URL.
    func lookUpPerson(_ person: PersonLookupRequest, group groupID: String) async throws(RemoteError) -> PersonMatchDTO? {
        let response: PersonLookupResponse = try await client.send("POST", ["v1", "groups", groupID, "people", "lookup"], route: "lookUpPerson",
                                                                   body: person, as: .account)
        return response.match
    }

    func sendInvitation(to person: PersonLookupRequest, group groupID: String) async throws(RemoteError) -> SentInvitationDTO {
        let response: SentInvitationResponse = try await client.send("POST", ["v1", "groups", groupID, "direct-invitations"],
                                                                     route: "sendDirectInvitation", body: person, as: .account)
        return response.invitation
    }

    func sentInvitations(group groupID: String) async throws(RemoteError) -> [SentInvitationDTO] {
        let response: SentInvitationListResponse = try await client.send("GET", ["v1", "groups", groupID, "direct-invitations"],
                                                                         route: "directInvitations", as: .account)
        return response.invitations
    }

    func cancelSentInvitation(_ invitationID: String, group groupID: String) async throws(RemoteError) -> SentInvitationDTO {
        let response: SentInvitationResponse = try await client.send("DELETE", ["v1", "groups", groupID, "direct-invitations", invitationID],
                                                                     route: "cancelDirectInvitation", as: .account)
        return response.invitation
    }

    func receivedInvitations() async throws(RemoteError) -> [ReceivedInvitationDTO] {
        let response: ReceivedInvitationListResponse = try await client.send("GET", ["v1", "account", "invitations"], route: "receivedInvitations",
                                                                             as: .account)
        return response.invitations
    }

    func acceptReceivedInvitation(_ invitationID: String) async throws(RemoteError) -> AcceptGroupInvitationResponse {
        try await client.send("POST", ["v1", "account", "invitations", invitationID, "accept"], route: "acceptDirectInvitation",
                              body: AcceptDirectInvitationRequest(), as: .account)
    }

    func declineReceivedInvitation(_ invitationID: String) async throws(RemoteError) -> DeclinedInvitationDTO {
        let response: DeclinedInvitationResponse = try await client.send("POST", ["v1", "account", "invitations", invitationID, "decline"],
                                                                         route: "declineDirectInvitation", body: AcceptDirectInvitationRequest(),
                                                                         as: .account)
        return response.invitation
    }
}
