import Foundation
@testable import SquareUp
import Testing

/// "Find a person" on the app side: what someone types is checked before anything is sent, the
/// address or number travels only in a request body, the answers decode, invitations waiting for
/// this account load with the groups and go once answered, and the screen's model moves from
/// search to sent. Addresses and numbers are fictional.
@Suite("Shared groups · direct invitations (Find a person)")
@MainActor
struct DirectInvitationTests {
    typealias Fix = SharedFixtures

    nonisolated static let us = PhoneRegion(code: "US", callingCode: 1)
    nonisolated static let lookupPath = "/v1/groups/\(Fix.id(Fix.groupID))/people/lookup"
    nonisolated static let sendPath = "/v1/groups/\(Fix.id(Fix.groupID))/direct-invitations"

    nonisolated static let profile = ProfileDTO(memberId: Fix.id(Fix.riley), displayName: "Riley", locale: "en_US", currency: "USD", destinations: [],
                                                createdAt: Fix.createdAt, updatedAt: Fix.createdAt)

    nonisolated static func received(_ id: String = "inv-1", group: String = "Dinner Squad") -> ReceivedInvitationDTO {
        ReceivedInvitationDTO(invitationId: id, status: "pending", groupName: group, symbol: "fork.knife", currency: "USD", inviterName: "Maya",
                              memberCount: 2, createdAt: Fix.createdAt, expiresAt: "2026-10-31T12:00:00.000000Z")
    }

    nonisolated static func sent(_ id: String = "inv-1", status: String = "pending", name: String = "Sam Rivera") -> SentInvitationDTO {
        SentInvitationDTO(invitationId: id, status: status, displayName: name, maskedIdentifier: "s•••@example.com",
                          invitedByMemberId: Fix.id(Fix.riley), createdAt: Fix.createdAt, expiresAt: "2026-10-31T12:00:00.000000Z",
                          respondedAt: status == "pending" ? nil : Fix.createdAt)
    }

    nonisolated static let match = PersonMatchDTO(displayName: "Sam Rivera", maskedIdentifier: "s•••@example.com", status: "available")

    nonisolated static func refusal(_ status: Int, _ code: String, _ message: String) -> (Int, Data) {
        (status, Fix.json(JSONValue.object(["error": .object(["code": .string(code), "message": .string(message), "requestId": "test"])])))
    }

    static func service(_ transport: ScriptedTransport) -> SharedGroupsService {
        let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:9", authMode: "development", firebaseAPIKey: nil)!
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.direct.\(UUID())"))
        let local = InMemoryLedgerStore(LedgerSnapshot(currentUserID: Fix.riley, members: [], groups: [], expenses: [], settlements: [],
                                                       defaultCurrency: .usd))
        return SharedGroupsService(configuration: configuration, account: account, transport: transport, cache: SharedGroupCache(root: nil),
                                   local: local, invitationLinks: KeychainStore(service: "test.direct.links.\(UUID())"))
    }

    /// Answers like the server for the account and group list; `extra` handles everything else.
    nonisolated static func server(_ extra: @escaping @Sendable (URLRequest) -> (Int, Data)?) -> ScriptedTransport {
        ScriptedTransport { request, _ in
            if let answer = extra(request) { return answer }
            switch Fix.path(request) {
            case "/v1/account": return (200, Fix.json(AccountResponse(account: AccountDTO(recoverable: true, emailVerified: true, profile: profile))))
            case "/v1/groups": return (200, Fix.json(GroupListResponse(groups: [])))
            default: return (404, Fix.json(JSONValue.object(["error": .object(["code": "not_found", "message": "Not Found", "requestId": "t"])])))
            }
        }
    }

    // MARK: - Checking what was typed

    @Test func emailsAreTrimmedAndLowerCased() {
        #expect(PersonIdentifier.checkEmail("  Sam.Rivera@Example.COM ") == .valid(.email("sam.rivera@example.com")))
        #expect(PersonIdentifier.checkEmail("a+trips@mail.example.co") == .valid(.email("a+trips@mail.example.co")))
        #expect(PersonIdentifier.checkEmail("   ") == .empty)
    }

    @Test(arguments: ["sam", "sam@", "@example.com", "sam@example", "sam@example.", "sam@@example.com", "sam rivera@example.com",
                      String(repeating: "x", count: 65) + "@example.com"])
    func malformedEmailsAreCaughtBeforeAnythingIsSent(_ text: String) {
        #expect(PersonIdentifier.checkEmail(text) == .invalid(.email))
    }

    @Test func phoneNumbersBecomeE164() {
        #expect(PersonIdentifier.checkPhone("(650) 555-3434", region: Self.us) == .valid(.phone("+16505553434")))
        #expect(PersonIdentifier.checkPhone("650.555.3434", region: Self.us) == .valid(.phone("+16505553434")))
        #expect(PersonIdentifier.checkPhone("+44 7400 123456", region: Self.us) == .valid(.phone("+447400123456")), "its own country code wins")
        #expect(PersonIdentifier.checkPhone("0044 7400 123456", region: Self.us) == .valid(.phone("+447400123456")))
        #expect(PersonIdentifier.checkPhone("650", region: Self.us) == .invalid(.phone))
        #expect(PersonIdentifier.checkPhone("", region: Self.us) == .empty)
    }

    @Test func aLookupSendsExactlyOneOfTheTwo() throws {
        let email = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(PersonIdentifier.email("sam@example.com").request))
        let phone = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(PersonIdentifier.phone("+16505550142").request))
        #expect(email == ["email": "sam@example.com"])
        #expect(phone == ["phone": "+16505550142"])
    }

    // MARK: - Wire

    @Test func answersDecode() throws {
        let none = try JSONDecoder().decode(PersonLookupResponse.self, from: Data(#"{"match":null}"#.utf8))
        #expect(none.match == nil)
        let found = try JSONDecoder().decode(PersonLookupResponse.self, from: Data("""
        {"match":{"displayName":"Sam Rivera","maskedIdentifier":"s\\u2022\\u2022\\u2022@example.com","status":"invited"}}
        """.utf8))
        #expect(found.match == PersonMatchDTO(displayName: "Sam Rivera", maskedIdentifier: "s•••@example.com", status: "invited"))
        let waiting = try JSONDecoder().decode(ReceivedInvitationListResponse.self, from: Data("""
        {"invitations":[{"invitationId":"i1","status":"pending","groupName":"Dinner Squad","symbol":"fork.knife","currency":"USD",
         "inviterName":"Maya","memberCount":3,"createdAt":"2026-10-01T12:00:00.000000Z","expiresAt":"2026-10-31T12:00:00.000000Z"}]}
        """.utf8))
        #expect(waiting.invitations.map(\.groupName) == ["Dinner Squad"])
        let sent = try JSONDecoder().decode(SentInvitationListResponse.self, from: Data("""
        {"invitations":[{"invitationId":"i1","status":"declined","displayName":"Sam","maskedIdentifier":"•••• 0142","invitedByMemberId":"m1",
         "createdAt":"2026-10-01T12:00:00.000000Z","expiresAt":"2026-10-31T12:00:00.000000Z","respondedAt":"2026-10-02T12:00:00.000000Z"}]}
        """.utf8))
        #expect(sent.invitations.first?.status == "declined")
    }

    // MARK: - The service

    @Test func lookingSomeoneUpSendsTheirAddressOnlyInTheBody() async throws {
        let transport = Self.server { request in
            Fix.path(request) == Self.lookupPath ? (200, Fix.json(PersonLookupResponse(match: Self.match))) : nil
        }
        let service = Self.service(transport)
        let match = try await service.lookUpPerson(.email("sam@example.com"), in: Fix.groupID)
        #expect(match == Self.match)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST" && Fix.body(request) == ["email": "sam@example.com"])
        #expect(request.url?.absoluteString.contains("sam") == false && request.url?.query == nil, "never in the URL")
    }

    @Test func nobodyToInviteIsNil() async throws {
        let service = Self.service(Self.server { Fix.path($0) == Self.lookupPath ? (200, Data(#"{"match":null}"#.utf8)) : nil })
        #expect(try await service.lookUpPerson(.phone("+16505550199"), in: Fix.groupID) == nil)
    }

    @Test func refusalsUseTheServersWords() async {
        let service = Self.service(Self.server { request in
            if Fix.path(request) == Self.sendPath { return Self.refusal(409, "invitation_exists", "They already have an invitation to this group") }
            if Fix.path(request) == Self.lookupPath { return Self.refusal(429, "rate_limited", "Too many requests. Try again shortly") }
            return nil
        })
        do {
            _ = try await service.invitePerson(.email("sam@example.com"), to: Fix.groupID)
            Issue.record("expected a refusal")
        } catch {
            #expect(LedgerErrorMessages.text(for: error) == "They already have an invitation to this group")
        }
        await #expect(throws: LedgerError.remote(.refused("Too many requests. Try again shortly"))) {
            _ = try await service.lookUpPerson(.email("sam@example.com"), in: Fix.groupID)
        }
    }

    @Test func refreshingGroupsAlsoReadsTheInvitationsWaitingForYou() async {
        final class Server: @unchecked Sendable { var waiting = [DirectInvitationTests.received("inv-1"), DirectInvitationTests.received("inv-2", group: "Ski")] }
        let server = Server()
        let service = Self.service(Self.server { request in
            Fix.path(request) == "/v1/account/invitations" ? (200, Fix.json(ReceivedInvitationListResponse(invitations: server.waiting))) : nil
        })
        await service.refreshAccount()
        await service.refreshGroups()
        #expect(service.receivedInvitations.map(\.id) == ["inv-1", "inv-2"])
        server.waiting = [Self.received("inv-2", group: "Ski")]
        await service.refreshGroups()
        #expect(service.receivedInvitations.map(\.id) == ["inv-2"], "one answered on another iPhone")
        service.close()
        #expect(service.receivedInvitations.isEmpty, "nothing of this account stays after it closes")
    }

    @Test func aServerWithoutDirectInvitationsChangesNothing() async {
        let service = Self.service(Self.server { _ in nil }) // /v1/account/invitations → 404
        await service.refreshAccount()
        await service.refreshGroups()
        #expect(service.receivedInvitations.isEmpty && service.listState != .idle)
    }

    @Test func acceptingJoinsTheGroupAndRemovesTheInvitation() async throws {
        let joined = Fix.snapshot(viewer: Fix.maya)
        let transport = Self.server { request in
            switch Fix.path(request) {
            case "/v1/account/invitations": (200, Fix.json(ReceivedInvitationListResponse(invitations: [Self.received()])))
            case "/v1/account/invitations/inv-1/accept": (201, Fix.json(AcceptGroupInvitationResponse(snapshot: joined, joined: true)))
            default: nil
            }
        }
        let service = Self.service(transport)
        await service.refreshAccount()
        await service.refreshGroups()
        let invitation = try #require(service.receivedInvitations.first)
        let groupID = try await service.accept(invitation)
        #expect(groupID == Fix.groupID && service.isShared(Fix.groupID))
        #expect(service.summaries.map(\.group.name) == ["Coastal Weekend"] && service.receivedInvitations.isEmpty)
        #expect(service.ledger(for: Fix.groupID)?.base == joined, "the group's data arrives only now")
    }

    @Test func aFailedAcceptanceSaysWhyAndShowsWhatsLeft() async throws {
        final class Server: @unchecked Sendable { var waiting = [DirectInvitationTests.received()] }
        let server = Server()
        let service = Self.service(Self.server { request in
            switch Fix.path(request) {
            case "/v1/account/invitations": return (200, Fix.json(ReceivedInvitationListResponse(invitations: server.waiting)))
            case "/v1/account/invitations/inv-1/accept":
                server.waiting = []
                return Self.refusal(410, "invitation_revoked", "This invitation was cancelled. Ask for a new one")
            default: return nil
            }
        })
        await service.refreshAccount()
        await service.refreshGroups()
        let invitation = try #require(service.receivedInvitations.first)
        await #expect(throws: LedgerError.remote(.invitation(.revoked))) { _ = try await service.accept(invitation) }
        #expect(service.receivedInvitations.isEmpty && service.summaries.isEmpty)
    }

    @Test func decliningRemovesItEvenIfItWasAlreadyGone() async throws {
        let service = Self.service(Self.server { request in
            switch Fix.path(request) {
            case "/v1/account/invitations":
                (200, Fix.json(ReceivedInvitationListResponse(invitations: [Self.received("inv-1"), Self.received("inv-2", group: "Ski")])))
            case "/v1/account/invitations/inv-1/decline":
                (200, Fix.json(DeclinedInvitationResponse(invitation: DeclinedInvitationDTO(invitationId: "inv-1", status: "declined",
                                                                                            respondedAt: Fix.createdAt))))
            case "/v1/account/invitations/inv-2/decline": Self.refusal(404, "not_found", "This invitation isn't available")
            default: nil
            }
        })
        await service.refreshAccount()
        await service.refreshGroups()
        try await service.decline(Self.received("inv-1"))
        #expect(service.receivedInvitations.map(\.id) == ["inv-2"])
        try await service.decline(Self.received("inv-2", group: "Ski"))
        #expect(service.receivedInvitations.isEmpty)
    }

    // MARK: - The screen's model

    @Test func theModelGoesFromSearchToSent() async {
        final class Server: @unchecked Sendable { var sent: [SentInvitationDTO] = [] }
        let server = Server()
        let transport = Self.server { request in
            switch (request.httpMethod, Fix.path(request)) {
            case ("POST", Self.lookupPath): return (200, Fix.json(PersonLookupResponse(match: Self.match)))
            case ("POST", Self.sendPath):
                server.sent = [Self.sent()]
                return (201, Fix.json(SentInvitationResponse(invitation: Self.sent())))
            case ("GET", Self.sendPath): return (200, Fix.json(SentInvitationListResponse(invitations: server.sent)))
            default: return nil
            }
        }
        let model = FindPersonModel(groupID: Fix.groupID, service: Self.service(transport), region: Self.us)
        await model.loadSent()
        #expect(model.sentInvitations.isEmpty)
        model.text = " Sam@Example.com"
        await model.search()
        #expect(model.phase == .found(Self.match, .email("sam@example.com")))
        await model.invite()
        #expect(model.phase == .sent(Self.sent()) && model.text.isEmpty, "ready for the next person")
        #expect(model.sentInvitations == [Self.sent()])
        let bodies = await transport.requests.filter { $0.httpMethod == "POST" }.map(Fix.body)
        #expect(bodies == [["email": "sam@example.com"], ["email": "sam@example.com"]], "inviting looks them up again by the same address")
        model.text = "m"
        #expect(model.phase == .idle, "typing starts a new search")
    }

    @Test func nothingIsSentForAnIncompleteEntry() async {
        let transport = Self.server { _ in nil }
        let model = FindPersonModel(groupID: Fix.groupID, service: Self.service(transport), region: Self.us)
        model.kind = .phone
        model.text = "650 55"
        #expect(model.issue == nil, "no complaint while typing")
        await model.search()
        #expect(model.issue?.contains("area code") == true && model.phase == .idle)
        model.kind = .email
        model.text = "sam@"
        await model.search()
        #expect(model.issue?.contains("full email address") == true)
        #expect(await transport.requests.isEmpty)
    }

    @Test func eachKindOfAnswerHasItsOwnPhase() async {
        final class Answer: @unchecked Sendable { var next: (Int, Data) = (200, Data(#"{"match":null}"#.utf8)) }
        let answer = Answer()
        let model = FindPersonModel(groupID: Fix.groupID, service: Self.service(Self.server { Fix.path($0) == Self.lookupPath ? answer.next : nil }),
                                    region: Self.us)
        model.text = "nobody@example.com"
        await model.search()
        #expect(model.phase == .noMatch)
        let member = PersonMatchDTO(displayName: "Maya", maskedIdentifier: "m•••@example.com", status: "member")
        answer.next = (200, Fix.json(PersonLookupResponse(match: member)))
        await model.search()
        #expect(model.phase == .found(member, .email("nobody@example.com")))
        await model.invite()
        #expect(model.phase == .found(member, .email("nobody@example.com")), "only someone available can be invited")
        answer.next = Self.refusal(410, "group_archived", "This group was archived")
        await model.search()
        #expect(model.phase == .failed("This group was archived"))
    }

    @Test func cancellingUpdatesTheList() async {
        let transport = Self.server { request in
            switch (request.httpMethod, Fix.path(request)) {
            case ("GET", Self.sendPath): (200, Fix.json(SentInvitationListResponse(invitations: [Self.sent()])))
            case ("DELETE", "\(Self.sendPath)/inv-1"): (200, Fix.json(SentInvitationResponse(invitation: Self.sent(status: "cancelled"))))
            default: nil
            }
        }
        let model = FindPersonModel(groupID: Fix.groupID, service: Self.service(transport), region: Self.us)
        await model.loadSent()
        await model.cancel(Self.sent())
        #expect(model.sentInvitations.map(\.status) == ["cancelled"] && model.cancelling.isEmpty && model.listError == nil)
        #expect(FindPersonView.statusText(Self.sent()).contains("Waiting for an answer"))
        #expect(FindPersonView.statusText(Self.sent(status: "declined")) == "Declined")
    }
}
