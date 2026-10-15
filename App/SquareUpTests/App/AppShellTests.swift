import Foundation
@testable import SquareUp
import Testing

@Suite("Deep links")
struct DeepLinkTests {
    let groupID = GroupID(UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000101")!)

    @Test("Parses every supported link")
    func parses() {
        #expect(DeepLink.parse(URL(string: "squp://home")!) == .home)
        #expect(DeepLink.parse(URL(string: "squp://groups")!) == .groups)
        #expect(DeepLink.parse(URL(string: "squp://group/\(groupID.rawValue.uuidString)")!) == .group(groupID))
        #expect(DeepLink.parse(URL(string: "squp://add")!) == .addExpense(nil))
        #expect(DeepLink.parse(URL(string: "squp://add?group=\(groupID.rawValue.uuidString)")!) == .addExpense(groupID))
        #expect(DeepLink.parse(URL(string: "squp://activity")!) == .activity)
    }

    @Test("Rejects foreign schemes and malformed identifiers")
    func rejects() {
        #expect(DeepLink.parse(URL(string: "https://example.com/group/x")!) == nil)
        #expect(DeepLink.parse(URL(string: "squp://group/not-a-uuid")!) == nil)
        #expect(DeepLink.parse(URL(string: "squp://unknown")!) == nil)
    }

    @Test("Round-trips through URLs", arguments: [
        DeepLink.home, .groups, .activity, .profile, .addExpense(nil),
    ])
    func roundTrip(link: DeepLink) {
        #expect(DeepLink.parse(link.url) == link)
    }

    @Test("Group links round-trip")
    func groupRoundTrip() {
        #expect(DeepLink.parse(DeepLink.group(groupID).url) == .group(groupID))
        #expect(DeepLink.parse(DeepLink.addExpense(groupID).url) == .addExpense(groupID))
    }
}

@Suite("Router")
@MainActor
struct AppRouterTests {
    @Test("The Add tab presents the composer without leaving the current tab")
    func addTab() {
        let router = AppRouter()
        router.select(.activity)
        router.select(.add)
        #expect(router.selectedTab == .activity)
        #expect(router.composer != nil)
    }

    @Test("Re-selecting the current tab pops to its root")
    func popToRoot() {
        let router = AppRouter()
        router.showGroup(SampleLedger.GroupKey.tahoe.id)
        #expect(router.homePath.count == 1)
        router.select(.home)
        #expect(router.homePath.isEmpty)
    }

    @Test("Group deep links open Groups with the group pushed")
    func openGroup() {
        let router = AppRouter()
        router.presentComposer()
        router.open(.group(SampleLedger.GroupKey.coastal.id))
        #expect(router.selectedTab == .groups)
        #expect(router.groupsPath == [.group(SampleLedger.GroupKey.coastal.id)])
        #expect(router.composer == nil)
    }

    @Test("Add links carry the group to the composer")
    func openAdd() {
        let router = AppRouter()
        router.open(.addExpense(SampleLedger.GroupKey.tahoe.id))
        #expect(router.composer?.groupID == SampleLedger.GroupKey.tahoe.id)
    }
}

@Suite("Launch configuration")
struct LaunchConfigurationTests {
    @Test("Parses UI-testing arguments")
    func parses() {
        let configuration = LaunchConfiguration.from(arguments: [
            "SquareUp", "-SUInMemoryStore", "-SUUITesting", "-SUReferenceDate", "812030400", "-SUScenario", "offline",
        ])
        #expect(configuration.usesInMemoryStore)
        #expect(configuration.isUITesting)
        #expect(configuration.referenceDate == DemoScenario.fixedReferenceDate)
        #expect(configuration.scenario == .offline)
    }

    @Test("Defaults to the real store")
    func defaults() {
        let configuration = LaunchConfiguration.from(arguments: ["SquareUp"])
        #expect(!configuration.usesInMemoryStore)
        #expect(configuration.scenario == nil)
    }

    @Test("A unit-test host never uses the on-disk store")
    func testHost() {
        let configuration = LaunchConfiguration.from(arguments: ["SquareUp"], environment: ["XCTestConfigurationFilePath": "/x"])
        #expect(configuration.usesInMemoryStore)
        #expect(configuration.isUITesting)
    }
}
