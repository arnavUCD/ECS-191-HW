import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Direct invitations ("Find a person") visual regression: the search with a match and with none,
/// the sheet a member (not the owner) opens, and invitations waiting at the top of Groups — dark,
/// narrow, and an accessibility size. Every view runs on a real `SharedGroupsService` over a
/// scripted transport.
@Suite("Snapshots · direct invitations", .serialized)
@MainActor
struct DirectInvitationSnapshotTests {
    typealias Fix = SharedFixtures

    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1500))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    private nonisolated static let account = AccountDTO(recoverable: true, emailVerified: true, profile: ProfileDTO(
        memberId: Fix.id(Fix.riley), displayName: "Riley", locale: "en_US", currency: "USD", destinations: [], createdAt: Fix.createdAt,
        updatedAt: Fix.createdAt
    ))

    private nonisolated static let waiting = [
        ReceivedInvitationDTO(invitationId: "r1", status: "pending", groupName: "Dinner Squad", symbol: "fork.knife", currency: "USD",
                              inviterName: "Maya Chen", memberCount: 4, createdAt: Fix.createdAt, expiresAt: "2026-10-25T12:00:00.000000Z"),
        ReceivedInvitationDTO(invitationId: "r2", status: "pending", groupName: "Ski Trip with a Rather Long Name", symbol: "snowflake",
                              currency: "EUR", inviterName: "Sam Okafor", memberCount: 1, createdAt: Fix.createdAt,
                              expiresAt: "2026-10-20T12:00:00.000000Z"),
    ]

    private nonisolated static let sent = [
        SentInvitationDTO(invitationId: "s1", status: "pending", displayName: "Ana Lopez", maskedIdentifier: "•••• 3434",
                          invitedByMemberId: Fix.id(Fix.riley), createdAt: Fix.createdAt, expiresAt: "2026-10-25T12:00:00.000000Z", respondedAt: nil),
        SentInvitationDTO(invitationId: "s2", status: "declined", displayName: "Lee Park", maskedIdentifier: "l•••@example.com",
                          invitedByMemberId: Fix.id(Fix.riley), createdAt: Fix.createdAt, expiresAt: "2026-10-25T12:00:00.000000Z",
                          respondedAt: Fix.createdAt),
    ]

    private static func transport(match: PersonMatchDTO?) -> ScriptedTransport {
        ScriptedTransport { request, _ in
            let path = Fix.path(request)
            switch path {
            case "/v1/account": return (200, Fix.json(AccountResponse(account: account)))
            case "/v1/groups": return (200, Fix.json(GroupListResponse(groups: [])))
            case "/v1/account/invitations": return (200, Fix.json(ReceivedInvitationListResponse(invitations: waiting)))
            default: break
            }
            if path.hasSuffix("/people/lookup") { return (200, Fix.json(PersonLookupResponse(match: match))) }
            if path.hasSuffix("/direct-invitations") { return (200, Fix.json(SentInvitationListResponse(invitations: sent))) }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: Fix.snapshot(viewer: Fix.riley))))
        }
    }

    private func environment(_ transport: ScriptedTransport) -> AppEnvironment {
        let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:9", authMode: "development", firebaseAPIKey: nil)!
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.snapshot.\(UUID())"))
        let local = InMemoryLedgerStore(LedgerSnapshot(currentUserID: Fix.riley, members: [], groups: [], expenses: [], settlements: [],
                                                       defaultCurrency: .usd), now: { DemoScenario.fixedReferenceDate })
        let service = SharedGroupsService(configuration: configuration, account: account, transport: transport, cache: SharedGroupCache(root: nil),
                                          local: local, now: { DemoScenario.fixedReferenceDate },
                                          invitationLinks: KeychainStore(service: "test.snapshot.links.\(UUID())"))
        return AppEnvironment(ledger: local, connectivity: ConnectivityMonitor(forcedStatus: .online), configuration: LaunchConfiguration(isUITesting: true),
                              fixedNow: DemoScenario.fixedReferenceDate, sharedGroups: service)
    }

    /// As the invitation sheet shows it.
    private func sheet(_ model: FindPersonModel, _ environment: AppEnvironment) -> some View {
        NavigationStack {
            ScrollView {
                FindPersonView(model: model)
                    .padding(.horizontal, SUSpacing.screenMargin)
                    .padding(.vertical, SUSpacing.lg)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Invite people"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(environment).squareUpTheme()
    }

    private func searched(_ text: String, match: PersonMatchDTO?) async -> (FindPersonModel, AppEnvironment) {
        let environment = environment(Self.transport(match: match))
        let model = FindPersonModel(groupID: Fix.groupID, service: environment.sharedGroups, region: PhoneRegion(code: "US", callingCode: 1))
        model.text = text
        await model.search()
        await model.loadSent()
        return (model, environment)
    }

    @Test func aPersonWasFound() async {
        let match = PersonMatchDTO(displayName: "Sam Rivera", maskedIdentifier: "s•••@example.com", status: "available")
        let (model, environment) = await searched("sam@example.com", match: match)
        let view = sheet(model, environment)
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 2600))
    }

    @Test func nobodyMatchesOrTheyreAlreadyInvited() async {
        let (none, environment) = await searched("nobody@example.com", match: nil)
        await assertScreen(sheet(none, environment), named: "noMatch")
        let invited = PersonMatchDTO(displayName: "Ana Lopez", maskedIdentifier: "a•••@example.com", status: "invited")
        let (already, again) = await searched("ana@example.com", match: invited)
        await assertScreen(sheet(already, again), named: "alreadyInvited")
    }

    @Test func aMemberOpensFindAPersonDirectly() async {
        let environment = environment(Self.transport(match: nil))
        let view = GroupInviteSheet(groupID: Fix.groupID, seat: nil, mode: .person, canMakeLinks: false)
            .environment(environment).squareUpTheme()
        await assertScreen(view, named: "dark")
    }

    @Test func invitationsWaitAtTheTopOfGroups() async {
        let environment = environment(Self.transport(match: nil))
        await environment.sharedGroups.refreshAccount()
        await environment.sharedGroups.refreshGroups()
        let view = NavigationStack { GroupsView() }
            .environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark")
        await assertScreen(view, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 2400))
    }
}
