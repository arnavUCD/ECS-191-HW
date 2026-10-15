import Foundation
@testable import SquareUp
import Testing

/// Multi-person shared groups on the app side: what older and newer servers send, invitation
/// states, the People screen's sections and standings, who may change an expense, the refusals
/// people see, and invitation links kept per account.
@Suite("Shared groups · people, invitations, and permissions")
@MainActor
struct GroupMembersTests {
    typealias Fix = SharedFixtures

    nonisolated static let now = RemoteRoomMapper.timestamp("2026-10-03T12:00:00.000000Z")!

    nonisolated static func invitation(_ id: String = UUID().uuidString.lowercased(), status: String? = "unused", createdAt: String = Fix.createdAt,
                                       expiresAt: String = "2026-10-08T12:00:00.000000Z", accepted: MemberID? = nil, revoked: Bool = false,
                                       code: String? = nil) -> GroupInvitationDTO {
        GroupInvitationDTO(invitationId: id, status: status, seatMemberId: nil, createdByMemberId: Fix.id(Fix.riley),
                           acceptedMemberId: accepted.map(Fix.id), createdAt: createdAt, expiresAt: expiresAt,
                           acceptedAt: accepted == nil ? nil : Fix.createdAt, revokedAt: revoked ? Fix.createdAt : nil, code: code,
                           url: code.map { "https://squareup.example/g/\($0)" }, appUrl: code.map { "squp://join-group/\($0)" })
    }

    // MARK: - Wire compatibility

    @Test func olderServersStillDecode() throws {
        let invitation = Data("""
        {"invitationId":"i1","seatMemberId":null,"createdAt":"2026-10-01T12:00:00.000000Z","expiresAt":"2026-10-08T12:00:00.000000Z",
         "acceptedAt":null,"revokedAt":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(GroupInvitationDTO.self, from: invitation)
        #expect(decoded.status == nil && decoded.acceptedMemberId == nil && decoded.createdByMemberId == nil)
        #expect(decoded.state(at: Self.now) == .unused, "derived when the server doesn't say")
        let preview = Data("""
        {"groupName":"Trip","symbol":"star","currency":"USD","inviterName":"Riley","memberCount":2,"expiresAt":"2026-10-08T12:00:00Z",
         "isSeatInvitation":false,"alreadyMember":false}
        """.utf8)
        #expect(try JSONDecoder().decode(GroupInvitationPreviewDTO.self, from: preview).ownerName == nil)
        let account = Data(#"{"recoverable":true,"profile":null}"#.utf8)
        #expect(try JSONDecoder().decode(AccountDTO.self, from: account).emailVerified == nil)
    }

    @Test func newerFieldsAreRead() throws {
        let data = Data("""
        {"invitationId":"i1","status":"accepted","seatMemberId":null,"createdByMemberId":"\(Fix.id(Fix.riley))",
         "acceptedMemberId":"\(Fix.id(Fix.maya))","createdAt":"2026-10-01T12:00:00.000000Z","expiresAt":"2026-10-08T12:00:00.000000Z",
         "acceptedAt":"2026-10-02T12:00:00.000000Z","revokedAt":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(GroupInvitationDTO.self, from: data)
        #expect(decoded.state(at: Self.now) == .accepted && decoded.acceptedMemberId == Fix.id(Fix.maya))
        let preview = Data("""
        {"groupName":"Trip","symbol":"star","currency":"USD","inviterName":"Riley","ownerName":"Maya","memberCount":2,
         "expiresAt":"2026-10-08T12:00:00Z","isSeatInvitation":false,"alreadyMember":false}
        """.utf8)
        #expect(try JSONDecoder().decode(GroupInvitationPreviewDTO.self, from: preview).ownerName == "Maya")
    }

    // MARK: - Invitation states

    @Test func invitationStates() {
        #expect(Self.invitation(status: "unused").state(at: Self.now) == .unused)
        #expect(Self.invitation(status: "revoked", revoked: true).state(at: Self.now) == .revoked)
        #expect(Self.invitation(status: "expired", expiresAt: "2026-10-02T12:00:00.000000Z").state(at: Self.now) == .expired)
        #expect(Self.invitation(status: "unused", expiresAt: "2026-10-03T11:59:00.000000Z").state(at: Self.now) == .expired,
                "an unused invitation whose time ran out since it was listed")
        // Without a status, the same order as the server: accepted, revoked, expired.
        #expect(Self.invitation(status: nil, accepted: Fix.maya).state(at: Self.now) == .accepted)
        #expect(Self.invitation(status: nil, revoked: true).state(at: Self.now) == .revoked)
        #expect(Self.invitation(status: nil, expiresAt: "2026-10-02T12:00:00.000000Z").state(at: Self.now) == .expired)
        #expect(Self.invitation(status: "accepted", expiresAt: "2026-10-02T12:00:00.000000Z", accepted: Fix.maya).state(at: Self.now) == .accepted,
                "used before it expired stays accepted")
    }

    // MARK: - The People screen

    static let sam = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a4")!)
    static let ana = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a5")!)

    /// Riley (owner) paid $90 for dinner with Maya and Sam; Ana joined later; Dev's place waits; Lee left.
    static func group(viewer: MemberID = Fix.maya, attempts: [GroupAttemptDTO] = []) -> GroupSnapshotDTO {
        let lee = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a6")!)
        return Fix.snapshot(
            viewer: viewer,
            expenses: [Fix.expense(total: 9000, shares: [(Fix.riley, 3000), (Fix.maya, 3000), (sam, 3000)], method: "equal")],
            attempts: attempts,
            members: [Fix.member(Fix.riley, "Riley"), Fix.member(Fix.maya, "Maya"), Fix.member(sam, "Sam"), Fix.member(ana, "Ana"),
                      Fix.member(Fix.dev, "Dev", status: "pending"), Fix.member(lee, "Lee", status: "removed")]
        )
    }

    static func people(_ dto: GroupSnapshotDTO, invitations: [GroupInvitationDTO] = []) throws -> GroupPeople {
        let workspace = try SharedGroupMapper.workspace(dto)
        let summary = try GroupSummaryBuilder.detail(for: Fix.groupID, in: workspace)
        let statuses = Dictionary(uniqueKeysWithValues: dto.members.map { ($0.id, $0.status) })
        return GroupPeople.make(summary: summary, ownerID: MemberID(string: dto.group.ownerMemberId),
                                status: { statuses[Fix.id($0)] }, invitations: invitations, now: now)
    }

    @Test func ownerMembersWaitingPlacesAndFormerMembersAreSeparate() throws {
        let people = try Self.people(Self.group())
        #expect(people.owner?.member.displayName == "Riley" && people.owner?.isOwner == true)
        #expect(people.members.map(\.member.displayName) == ["Maya", "Ana", "Sam"], "you first, then by name; the owner apart")
        #expect(people.waitingPlaces.map(\.displayName) == ["Dev"])
        #expect(people.former.map(\.displayName) == ["Lee"], "former members are listed, not counted")
        #expect(people.activeCount == 4 && !people.isFull)
    }

    @Test func eachPersonShowsHowTheyStand() throws {
        let people = try Self.people(Self.group())
        let usd = { Money(minorUnits: $0, currency: .usd) }
        #expect(people.owner?.standing == .isOwed(usd(6000)))
        let standings = Dictionary(uniqueKeysWithValues: people.members.map { ($0.member.displayName, $0.standing) })
        #expect(standings == ["Maya": .owes(usd(3000)), "Sam": .owes(usd(3000)), "Ana": .settled], "Ana joined after the dinner")
        #expect(people.members.first { $0.member.displayName == "Ana" }?.canLeave == true)
        #expect(people.members.first { $0.member.displayName == "Sam" }?.canLeave == false)
    }

    @Test func aPaymentInProgressIsShownForBothPeople() throws {
        let attempt = GroupAttemptDTO(id: UUID().uuidString.lowercased(), payerId: Fix.id(Self.sam), recipientId: Fix.id(Fix.riley),
                                      destinationId: nil, provider: "cash", amount: 3000, memo: "", state: "reportedSent",
                                      history: [AttemptTransitionDTO(state: "reportedSent", actorId: Fix.id(Self.sam), at: Fix.createdAt, note: nil)],
                                      externalReference: nil, settlementId: nil)
        let people = try Self.people(Self.group(attempts: [attempt]))
        #expect(people.owner?.hasPaymentInProgress == true)
        #expect(people.members.first { $0.member.displayName == "Sam" }?.hasPaymentInProgress == true)
        #expect(people.members.first { $0.member.displayName == "Maya" }?.hasPaymentInProgress == false, "Maya isn't part of it")
    }

    @Test func invitationsAreSplitIntoWaitingAndEnded() throws {
        let waiting = Self.invitation("w", createdAt: "2026-10-02T12:00:00.000000Z")
        let newer = Self.invitation("n", createdAt: "2026-10-03T08:00:00.000000Z")
        let accepted = Self.invitation("a", status: "accepted", accepted: Fix.maya)
        let revoked = Self.invitation("r", status: "revoked", revoked: true)
        let expired = Self.invitation("e", status: "unused", expiresAt: "2026-10-03T00:00:00.000000Z")
        let people = try Self.people(Self.group(viewer: Fix.riley), invitations: [waiting, accepted, revoked, newer, expired])
        #expect(people.awaiting.map(\.invitationId) == ["n", "w"], "newest first")
        #expect(Set(people.ended.map(\.invitationId)) == ["a", "r", "e"])
    }

    @Test func twentyFivePeopleFillTheGroup() throws {
        var members = [Fix.member(Fix.riley, "Riley")]
        for index in 1..<25 {
            members.append(Fix.member(MemberID(UUID(uuidString: String(format: "b0000000-0000-4000-8000-%012d", index))!), "Person \(index)"))
        }
        members.append(Fix.member(MemberID(), "Gone", status: "removed"))
        let people = try Self.people(Fix.snapshot(viewer: Fix.riley, members: members))
        #expect(people.activeCount == 25 && people.isFull, "removed people don't count")
        #expect(people.members.count == 24)
    }

    // MARK: - Who may change an expense

    @Test func expensePermissions() {
        let byMaya = Expense(groupID: Fix.groupID, title: "Taxi", date: Self.now, total: Money(minorUnits: 100, currency: .usd), category: .transport,
                             splitMethod: .exact, payments: [Share(Fix.maya, Money(minorUnits: 100, currency: .usd))],
                             allocations: [Share(Fix.maya, Money(minorUnits: 100, currency: .usd))], createdBy: Fix.maya)
        #expect(ExpensePermissions.shared(byMaya, viewer: Fix.maya, isOwner: false, isArchived: false)
            == ExpensePermissions(canEdit: true, canDelete: true, actsAsOwner: false))
        #expect(ExpensePermissions.shared(byMaya, viewer: Fix.riley, isOwner: true, isArchived: false)
            == ExpensePermissions(canEdit: false, canDelete: true, actsAsOwner: true), "the owner resolves, but doesn't rewrite")
        #expect(ExpensePermissions.shared(byMaya, viewer: Self.sam, isOwner: false, isArchived: false)
            == ExpensePermissions(canEdit: false, canDelete: false, actsAsOwner: false))
        #expect(ExpensePermissions.shared(byMaya, viewer: Fix.maya, isOwner: true, isArchived: true).canDelete == false)
        #expect(ExpensePermissions.local == ExpensePermissions(canEdit: true, canDelete: true, actsAsOwner: false))
    }

    // MARK: - Refusals

    @Test func refusalsPeopleCanActOn() {
        let refusal = { (status: Int, code: String) in
            RemoteError.server(ServerRefusal(status: status, code: code, message: "Refused", currentRevision: nil, retryAfterSeconds: nil, room: nil))
        }
        let unverified = refusal(403, "email_not_verified")
        #expect(LedgerError.from(unverified) == .remote(.emailNotVerified))
        let full = refusal(409, "group_full")
        #expect(LedgerError.from(groupInvitation: full) == .remote(.invitation(.groupFull)))
        #expect(LedgerErrorMessages.text(for: LedgerError.remote(.emailNotVerified)).contains("Verify"))
        #expect(LedgerErrorMessages.text(for: GroupInvitationIssue.groupFull).contains("25"))
    }

    // MARK: - Invitation links, per account

    static func service(_ transport: ScriptedTransport, links: KeychainStore, accountKeychain: KeychainStore) -> SharedGroupsService {
        let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:9", authMode: "development", firebaseAPIKey: nil)!
        let account = AccountSession(configuration: configuration, transport: transport, keychain: accountKeychain)
        let local = InMemoryLedgerStore(LedgerSnapshot(currentUserID: Fix.riley, members: [], groups: [], expenses: [], settlements: [],
                                                       defaultCurrency: .usd))
        return SharedGroupsService(configuration: configuration, account: account, transport: transport, cache: SharedGroupCache(root: nil),
                                   local: local, now: { now }, invitationLinks: links)
    }

    @Test func anUnusedInvitationsLinkCanBeShownAgainUntilItEnds() async throws {
        final class Server: @unchecked Sendable { var listed: [GroupInvitationDTO] = [] }
        let server = Server()
        let made = Self.invitation("inv-1", code: "7KQ2-M9XA-4RT8-WC3D-HP6N")
        let transport = ScriptedTransport { request, _ in
            let path = Fix.path(request)
            if path == "/v1/account" {
                return (200, Fix.json(AccountResponse(account: AccountDTO(recoverable: true, emailVerified: true, profile: nil))))
            }
            if path.hasSuffix("/invitations"), request.httpMethod == "POST" { return (201, Fix.json(GroupInvitationResponse(invitation: made))) }
            if path.hasSuffix("/invitations") { return (200, Fix.json(GroupInvitationListResponse(invitations: server.listed))) }
            if request.httpMethod == "DELETE" {
                return (200, Fix.json(GroupInvitationResponse(invitation: Self.invitation("inv-1", status: "revoked", revoked: true))))
            }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: Fix.snapshot(viewer: Fix.riley))))
        }
        let links = KeychainStore(service: "test.links.\(UUID())")
        let riley = Self.service(transport, links: links, accountKeychain: KeychainStore(service: "test.account.\(UUID())"))
        await riley.refreshAccount()
        _ = try await riley.createInvitation(for: Fix.groupID, seat: nil)
        #expect(riley.savedLink(for: "inv-1") == SharedGroupsService.InvitationLink(code: "7KQ2-M9XA-4RT8-WC3D-HP6N",
                                                                                    url: "https://squareup.example/g/7KQ2-M9XA-4RT8-WC3D-HP6N",
                                                                                    appUrl: "squp://join-group/7KQ2-M9XA-4RT8-WC3D-HP6N"))
        let someoneElse = Self.service(transport, links: links, accountKeychain: KeychainStore(service: "test.account.\(UUID())"))
        await someoneElse.refreshAccount()
        #expect(someoneElse.accountID != riley.accountID)
        #expect(someoneElse.savedLink(for: "inv-1") == nil, "another account on this iPhone never sees it")

        server.listed = [Self.invitation("inv-1", status: "unused")]
        _ = try await riley.invitations(for: Fix.groupID)
        #expect(riley.savedLink(for: "inv-1") != nil, "still usable: kept")
        server.listed = [Self.invitation("inv-1", status: "accepted", accepted: Fix.maya)]
        _ = try await riley.invitations(for: Fix.groupID)
        #expect(riley.savedLink(for: "inv-1") == nil, "used: forgotten")

        _ = try await riley.createInvitation(for: Fix.groupID, seat: nil)
        let revoked = try await riley.revokeInvitation("inv-1", in: Fix.groupID)
        #expect(revoked.state(at: Self.now) == .revoked && riley.savedLink(for: "inv-1") == nil)
    }

    @Test func eachInvitationRequestMakesANewOne() async throws {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let transport = ScriptedTransport { request, _ in
            if Fix.path(request).hasSuffix("/invitations"), request.httpMethod == "POST" {
                count.value += 1
                return (201, Fix.json(GroupInvitationResponse(invitation: Self.invitation("inv-\(count.value)", code: "CODE-\(count.value)"))))
            }
            if Fix.path(request) == "/v1/account" {
                return (200, Fix.json(AccountResponse(account: AccountDTO(recoverable: true, emailVerified: true, profile: nil))))
            }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: Fix.snapshot(viewer: Fix.riley))))
        }
        let service = Self.service(transport, links: KeychainStore(service: "test.links.\(UUID())"),
                                   accountKeychain: KeychainStore(service: "test.account.\(UUID())"))
        await service.refreshAccount()
        let first = try await service.createInvitation(for: Fix.groupID, seat: nil)
        let second = try await service.createInvitation(for: Fix.groupID, seat: nil)
        #expect(first.invitationId != second.invitationId && first.code != second.code)
        #expect(service.savedLink(for: first.invitationId)?.code == "CODE-1" && service.savedLink(for: second.invitationId)?.code == "CODE-2")
        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.allSatisfy { Fix.body($0) == ["seatMemberId": nil] || Fix.body($0) == [:] }, "no placeholder seat")
    }
}
