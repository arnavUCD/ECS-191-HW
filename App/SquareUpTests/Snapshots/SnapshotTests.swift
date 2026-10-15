import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Visual regression for the design system and critical screens (CLAUDE.md §16).
///
/// References live in `__Snapshots__/` beside this file and are recorded on the
/// iPhone 18 Pro simulator (iOS 27.0, @3x). A missing reference is recorded on first run and
/// that run fails by design; re-run to verify. Re-record deliberately after intentional design
/// changes with `withSnapshotTesting(record: .all)`.
///
/// Views are hosted in a real `UIWindow` so `.task` loading completes before capture, and the
/// hero aurora is frozen (`-SUUITesting` semantics) so frames are deterministic.
@MainActor
enum SnapshotHost {
    static let phone = CGSize(width: 402, height: 874)
    static let compactPhone = CGSize(width: 320, height: 700)
    static let wide = CGSize(width: 1024, height: 900)

    static func environment(_ scenario: DemoScenario) -> AppEnvironment {
        scenario.environment(configuration: LaunchConfiguration(isUITesting: true))
    }

    /// An environment over an arbitrary ledger state (built with `EngineHarness`).
    static func environment(_ state: LedgerSnapshot) -> AppEnvironment {
        AppEnvironment(
            ledger: InMemoryLedgerStore(state, now: { DemoScenario.fixedReferenceDate }),
            connectivity: ConnectivityMonitor(forcedStatus: .online),
            configuration: LaunchConfiguration(isUITesting: true),
            fixedNow: DemoScenario.fixedReferenceDate
        )
    }

    static func screen<V: View>(_ state: LedgerSnapshot, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack { content() }
            .environment(environment(state))
            .environment(AppRouter())
            .squareUpTheme()
    }

    static func render<V: View>(
        _ view: V,
        size: CGSize,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast = .normal,
        settle: Duration = .milliseconds(1200)
    ) async -> UIImage {
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = UIColor(resource: .backgroundPrimary)
        // Windows must belong to a scene to render on iOS 26+; borrow the test host's scene.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("Test host has no window scene")
            return UIImage()
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.traitOverrides.accessibilityContrast = contrast
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: settle)
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// A screen as it appears inside its tab: navigation stack plus app environment.
    static func screen<V: View>(_ scenario: DemoScenario, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack { content() }
            .environment(environment(scenario))
            .environment(AppRouter())
            .squareUpTheme()
    }
}

/// 99% of pixels must match exactly. Perceptual (Core Image Lab ΔE) comparison is not used:
/// on the simulator its GPU path produced bimodal results for byte-identical renders.
private let precision: Float = 0.99

@Suite("Snapshots · components", .serialized)
@MainActor
struct ComponentSnapshotTests {
    private func assertComponent<V: View>(
        _ view: V, named name: String, width: CGFloat = 402, height: CGFloat,
        style: UIUserInterfaceStyle = .dark, fileID: StaticString = #fileID, file: StaticString = #filePath,
        testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(
            view.padding(SUSpacing.md).frame(width: width, height: height, alignment: .top).background(SUColor.backgroundPrimary),
            size: CGSize(width: width, height: height),
            style: style
        )
        assertSnapshot(of: image, as: .image(precision: precision), named: name,
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    @Test func balanceHero() async {
        let owed = NetPosition(owedToYou: Money(Decimal(string: "552.30")!), youOwe: Money(Decimal(string: "29.69")!))
        let owe = NetPosition(owedToYou: Money(12), youOwe: Money(Decimal(string: "1250480.75")!))
        let square = NetPosition(owedToYou: .zero(), youOwe: .zero())
        func pocket(_ position: NetPosition, groups: Int) -> some View {
            VStack(spacing: SUSpacing.md) {
                SUWallet(cardCount: 0, isAnimated: false) { _ in EmptyView() } pocket: {
                    SUBalanceCard(position: position, groupCount: groups)
                }
                SUOpenBalancesCard(position: position)
            }
        }
        await assertComponent(pocket(owed, groups: 4), named: "owed-dark", height: 520)
        await assertComponent(pocket(owe, groups: 2), named: "owe-large-dark", height: 520)
        await assertComponent(pocket(square, groups: 1).dynamicTypeSize(.accessibility3), named: "square-ax3", height: 900)
    }

    @Test func transactionRows() async {
        let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
        let entries = Array(ActivityFeedBuilder.entries(from: snapshot).prefix(6))
        let list = SUCard {
            VStack(spacing: 0) {
                ForEach(entries) { SUTransactionRow(entry: $0, members: snapshot.members) }
            }
        }
        await assertComponent(list, named: "dark", height: 560)
    }

    @Test func badgesAndStatus() async {
        let view = VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack { SURoleBadge(kind: .payer); SURoleBadge(kind: .you) }
            HStack { SUStatusChip.offline; SUStatusChip.savedOnDevice; SUStatusChip.settled }
        }
        await assertComponent(view, named: "dark", height: 460)
    }

    @Test func pickers() async {
        let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
        let members = snapshot.members(of: snapshot.group(SampleLedger.GroupKey.tahoe.id)!)
        let view = VStack(alignment: .leading, spacing: SUSpacing.md) {
            SUSplitMethodPicker(selection: .constant(.exact))
            SUAvatarStack(members: members, currentUserID: members.first?.id, size: .medium)
            SUUserPickerRow(member: members[0], detail: "@riley", isCurrentUser: true, isSelected: true) {}
            SUUserPickerRow(member: members[2], detail: "@arivera", isSelected: false) {}
        }
        await assertComponent(view, named: "dark", height: 360)
    }
}

@Suite("Snapshots · screens", .serialized)
@MainActor
struct ScreenSnapshotTests {
    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
        line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style)
        assertSnapshot(of: image, as: .image(precision: precision), named: name,
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    @Test func homeStates() async {
        await assertScreen(SnapshotHost.screen(.standard) { HomeView() }, named: "owed-dark")
        await assertScreen(SnapshotHost.screen(.owes) { HomeView() }, named: "owes-dark")
        await assertScreen(SnapshotHost.screen(.newUser) { HomeView() }, named: "new-user-dark")
        await assertScreen(SnapshotHost.screen(.failure) { HomeView() }, named: "error-dark")
        await assertScreen(SnapshotHost.screen(.offline) { HomeView() }, named: "offline-dark")
    }

    @Test func homeAccessibilityAndSizes() async {
        await assertScreen(
            SnapshotHost.screen(.longNames) { HomeView() }.dynamicTypeSize(.accessibility2),
            named: "long-names-ax2"
        )
        await assertScreen(SnapshotHost.screen(.largeAmounts) { HomeView() }, named: "compact-width", size: SnapshotHost.compactPhone)
        await assertScreen(SnapshotHost.screen(.standard) { HomeView() }, named: "wide-two-column", size: SnapshotHost.wide)
    }

    @Test func groupDetail() async {
        await assertScreen(
            SnapshotHost.screen(.standard) { GroupDetailView(groupID: SampleLedger.GroupKey.coastal.id) },
            named: "coastal-dark"
        )
    }

    @Test func groupsAndActivity() async {
        await assertScreen(SnapshotHost.screen(.standard) { GroupsView() }, named: "groups-dark")
        await assertScreen(SnapshotHost.screen(.standard) { ActivityView() }, named: "activity-dark")
    }

    @Test func compose() async {
        let view = ComposeExpenseView(request: ComposerRequest(groupID: SampleLedger.GroupKey.apartment.id))
            .environment(SnapshotHost.environment(.standard))
            .environment(AppRouter())
            .squareUpTheme()
        await assertScreen(view, named: "amount-step-dark")
    }
}
