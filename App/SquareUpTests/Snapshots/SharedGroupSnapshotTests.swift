import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Milestone 7 visual regression (§16.2): a shared group up to date, offline with a change waiting to
/// send, the invitation sheet, and the join preview — light, dark, narrow, and an accessibility size.
/// Every view runs on a real `SharedGroupLedger` / `SharedGroupsService` over a scripted transport.
@Suite("Snapshots · M7 shared groups", .serialized)
@MainActor
struct SharedGroupSnapshotTests {
    typealias Fix = SharedFixtures

    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1800))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    /// Maya's view of a group where Riley paid $60.00 for gas, split equally.
    private nonisolated static let snapshot = Fix.snapshot(
        expenses: [Fix.expense(ExpenseID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000e1")!), title: "Gas", total: 6000,
                               shares: [(Fix.riley, 3000), (Fix.maya, 3000)], method: "equal")],
        members: [Fix.member(Fix.riley, "Riley"), Fix.member(Fix.maya, "Maya")]
    )

    private nonisolated static let invitation = GroupInvitationDTO(
        invitationId: "inv-1", status: "unused", seatMemberId: nil, createdAt: "2026-09-25T11:00:00.000000Z",
        expiresAt: "2026-10-02T11:00:00.000000Z", acceptedAt: nil,
        revokedAt: nil, code: "7KQ2-M9XA-4RT8-WC3D-HP6N", url: "https://squareup.example/g/7KQ2M9XA4RT8WC3DHP6N",
        appUrl: "squp://join-group/7KQ2M9XA4RT8WC3DHP6N"
    )

    private nonisolated static let preview = GroupInvitationPreviewDTO(
        groupName: "Coastal Weekend", symbol: "beach.umbrella.fill", currency: "USD", inviterName: "Riley", ownerName: "Riley", memberCount: 3,
        expiresAt: "2026-10-08T12:00:00.000000Z", isSeatInvitation: false, alreadyMember: false
    )

    private nonisolated static let account = AccountDTO(recoverable: true, profile: ProfileDTO(
        memberId: Fix.id(Fix.maya), displayName: "Maya", locale: "en_US", currency: "USD", destinations: [], createdAt: Fix.createdAt,
        updatedAt: Fix.createdAt
    ))

    /// Answers like the server: the group, empty change pages, an invitation, and a preview.
    private static func online() -> ScriptedTransport {
        ScriptedTransport { request, _ in
            let path = Fix.path(request)
            if path == "/v1/account" { return (200, Fix.json(AccountResponse(account: account))) }
            if path.hasSuffix("/changes") { return (200, Fix.json(GroupChangesResponse(changes: Fix.changes(from: snapshot, to: snapshot)))) }
            if path.hasSuffix("/invitations") { return (201, Fix.json(GroupInvitationResponse(invitation: invitation))) }
            if path.hasPrefix("/v1/group-invitations/") { return (200, Fix.json(GroupInvitationPreviewResponse(invitation: preview))) }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: snapshot)))
        }
    }

    private static func offline() -> ScriptedTransport {
        ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
    }

    private func environment(_ transport: ScriptedTransport) -> (AppEnvironment, SharedGroupLedger) {
        let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:9", authMode: "development", firebaseAPIKey: nil)!
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.snapshot.\(UUID())"))
        let local = InMemoryLedgerStore(LedgerSnapshot(currentUserID: Fix.maya, members: [], groups: [], expenses: [], settlements: [],
                                                       defaultCurrency: .usd), now: { DemoScenario.fixedReferenceDate })
        let service = SharedGroupsService(configuration: configuration, account: account, transport: transport, cache: SharedGroupCache(root: nil),
                                          local: local)
        let ledger = SharedGroupLedger(groupID: Fix.groupID, account: "snapshot", api: Fix.api(transport), cache: SharedGroupCache(root: nil),
                                       profile: { nil }, initial: Self.snapshot, now: { DemoScenario.fixedReferenceDate })
        let base = AppEnvironment(ledger: local, connectivity: ConnectivityMonitor(forcedStatus: .online),
                                  configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate,
                                  sharedGroups: service)
        return (base.shared(group: ledger), ledger)
    }

    private func detail(_ environment: AppEnvironment) -> some View {
        NavigationStack { GroupDetailView(groupID: Fix.groupID) }
            .environment(environment).environment(AppRouter()).squareUpTheme()
    }

    @Test func sharedGroupUpToDate() async throws {
        // Each capture gets its own freshly refreshed ledger: the screen polls while it's visible,
        // and a shared ledger's next scheduled poll could land mid-capture ("Checking for changes").
        func upToDate() async throws -> some View {
            let (environment, ledger) = environment(Self.online())
            try await ledger.refresh()
            return detail(environment)
        }
        await assertScreen(try upToDate(), named: "dark")
        await assertScreen(try upToDate(), named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(try upToDate().dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1600))
    }

    @Test func offlineWithAChangeWaitingToSend() async throws {
        let (environment, ledger) = environment(Self.offline())
        let expense = Expense(id: ExpenseID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000e2")!), groupID: Fix.groupID, title: "Snacks",
                              date: DemoScenario.fixedReferenceDate, total: Money(minorUnits: 1200, currency: .usd), category: .groceries,
                              splitMethod: .equal, payments: [Share(Fix.maya, Money(minorUnits: 1200, currency: .usd))],
                              allocations: [Share(Fix.riley, Money(minorUnits: 600, currency: .usd)), Share(Fix.maya, Money(minorUnits: 600, currency: .usd))],
                              createdBy: Fix.maya)
        await #expect(throws: LedgerError.remote(.offline)) { _ = try await ledger.perform(.addExpense(expense), as: Fix.maya) }
        #expect(ledger.unsent.count == 1, "queued with its idempotency key while offline")
        let view = detail(environment)
        await assertScreen(view, named: "dark")
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1800))
    }

    @Test func invitationSheet() async {
        let (environment, _) = environment(Self.online())
        let sheet = GroupInviteSheet(groupID: Fix.groupID, seat: nil)
            .environment(environment).squareUpTheme()
        await assertScreen(sheet, named: "dark")
        await assertScreen(sheet, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(sheet.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 2000))
    }

    // MARK: - People and invitations (multi-person groups)

    private nonisolated static let sam = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a4")!)
    private nonisolated static let ana = MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a5")!)

    /// Riley's (the owner's) view: $90 dinner Riley paid for Maya and Sam; Ana joined later; Lee left.
    private nonisolated static let ownerSnapshot = Fix.snapshot(
        viewer: Fix.riley,
        expenses: [Fix.expense(ExpenseID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000e3")!), title: "Dinner", total: 9000,
                               shares: [(Fix.riley, 3000), (Fix.maya, 3000), (sam, 3000)], method: "equal")],
        members: [Fix.member(Fix.riley, "Riley", providers: ["venmo"]), Fix.member(Fix.maya, "Maya Chen"), Fix.member(sam, "Sam Okafor"),
                  Fix.member(ana, "Ana Lopez"), Fix.member(MemberID(UUID(uuidString: "a0000000-0000-4000-8000-0000000000a6")!), "Lee", status: "removed")]
    )

    private nonisolated static func listed(_ id: String, _ status: String, created: String, accepted: MemberID? = nil) -> GroupInvitationDTO {
        GroupInvitationDTO(invitationId: id, status: status, seatMemberId: nil, createdByMemberId: Fix.id(Fix.riley), acceptedMemberId: accepted.map(Fix.id),
                           createdAt: created, expiresAt: status == "expired" ? "2026-09-20T12:00:00.000000Z" : "2026-09-30T12:00:00.000000Z",
                           acceptedAt: accepted == nil ? nil : created, revokedAt: status == "revoked" ? created : nil, code: nil, url: nil, appUrl: nil)
    }

    private nonisolated static let ownersInvitations = [
        listed("i-unused-1", "unused", created: "2026-09-24T18:00:00.000000Z"),
        listed("i-unused-2", "unused", created: "2026-09-23T09:30:00.000000Z"),
        listed("i-accepted", "accepted", created: "2026-09-21T12:00:00.000000Z", accepted: ana),
        listed("i-revoked", "revoked", created: "2026-09-19T12:00:00.000000Z"),
        listed("i-expired", "expired", created: "2026-09-13T12:00:00.000000Z"),
    ]

    private static func ownerOnline() -> ScriptedTransport {
        ScriptedTransport { request, _ in
            let path = Fix.path(request)
            if path.hasSuffix("/changes") { return (200, Fix.json(GroupChangesResponse(changes: Fix.changes(from: ownerSnapshot, to: ownerSnapshot)))) }
            if path.hasSuffix("/invitations") { return (200, Fix.json(GroupInvitationListResponse(invitations: ownersInvitations))) }
            return (200, Fix.json(GroupSnapshotResponse(snapshot: ownerSnapshot)))
        }
    }

    private func people(_ environment: AppEnvironment, _ ledger: SharedGroupLedger) async throws -> some View {
        let summary = try await GroupSummaryBuilder.detail(for: Fix.groupID, in: try ledger.snapshot())
        return NavigationStack {
            ScrollView {
                SharedGroupMembersSection(ledger: ledger, summary: summary)
                    .padding(SUSpacing.screenMargin)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "People"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(environment).environment(AppRouter()).squareUpTheme()
    }

    @Test func ownersPeopleScreen() async throws {
        let transport = Self.ownerOnline()
        let (base, _) = environment(transport)
        let ledger = SharedGroupLedger(groupID: Fix.groupID, account: "snapshot", api: Fix.api(transport), cache: SharedGroupCache(root: nil),
                                       profile: { nil }, initial: Self.ownerSnapshot, now: { DemoScenario.fixedReferenceDate })
        let environment = base.shared(group: ledger)
        let view = try await people(environment, ledger)
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 1500))
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 3200))
    }

    @Test func membersPeopleScreen() async throws {
        // Maya's view of the same group: no invitations, a Leave button, her own standing first.
        let mayaSnapshot = Fix.snapshot(viewer: Fix.maya, expenses: Self.ownerSnapshot.expenses, members: Self.ownerSnapshot.members)
        let transport = ScriptedTransport { _, _ in (200, Fix.json(GroupSnapshotResponse(snapshot: mayaSnapshot))) }
        let (base, _) = environment(transport)
        let ledger = SharedGroupLedger(groupID: Fix.groupID, account: "snapshot", api: Fix.api(transport), cache: SharedGroupCache(root: nil),
                                       profile: { nil }, initial: mayaSnapshot, now: { DemoScenario.fixedReferenceDate })
        let view = try await people(base.shared(group: ledger), ledger)
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 1100))
        await assertScreen(view, named: "narrow", size: CGSize(width: SnapshotHost.compactPhone.width, height: 1100))
    }

    @Test func invitationDetails() async {
        let (environment, _) = environment(Self.online())
        let accepted = GroupInviteSheet(groupID: Fix.groupID, seat: nil, existing: Self.ownersInvitations[2],
                                        members: [Self.ana: Member(id: Self.ana, displayName: "Ana Lopez")])
            .environment(environment).squareUpTheme()
        await assertScreen(accepted, named: "accepted")
        let elsewhere = GroupInviteSheet(groupID: Fix.groupID, seat: nil, existing: Self.ownersInvitations[0])
            .environment(environment).squareUpTheme()
        await assertScreen(elsewhere, named: "unusedMadeElsewhere")
        await assertScreen(elsewhere.dynamicTypeSize(.accessibility2), named: "unusedMadeElsewhere.ax2", size: CGSize(width: 402, height: 1600))
    }

    @Test func joinPreview() async {
        let (environment, _) = environment(Self.online())
        await environment.sharedGroups.refreshAccount() // as at launch: a signed-in account with a name
        let view = JoinGroupView(initialCode: "7KQ2M9XA4RT8WC3DHP6N") { _ in }
            .environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark")
        await assertScreen(view.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1600))
    }
}
