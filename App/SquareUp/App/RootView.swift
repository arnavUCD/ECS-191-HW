import SwiftUI

/// The application shell: five tabs with Add Expense as the iOS 27 prominent tab.
///
/// The prominent tab is a system-rendered Liquid Glass control, so it keeps correct VoiceOver,
/// keyboard, pointer, and Reduce Transparency behaviour without a custom floating tab bar.
/// Selecting it presents the composer sheet and leaves the current tab in place.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// The launch flow, when this build requires an account.
    @Environment(AuthCoordinator.self) private var auth: AuthCoordinator?
    /// Which account's data is open (offers earlier data to its rightful owner).
    @Environment(AppSession.self) private var session: AppSession?

    var body: some View {
        @Bindable var router = router
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                TabRoot(path: $router.homePath) { HomeView() }
            }
            Tab("Groups", systemImage: "person.2", value: AppTab.groups) {
                TabRoot(path: $router.groupsPath) { GroupsView() }
            }
            // Invitations sent to this account, waiting for an answer at the top of Groups.
            .badge(environment.sharedGroups.receivedInvitations.count)
            Tab("Add Expense", systemImage: "plus", value: AppTab.add, role: .prominent) {
                // Never shown: selecting this tab presents the composer.
                Color.clear
            }
            Tab("Activity", systemImage: "clock", value: AppTab.activity) {
                TabRoot(path: $router.activityPath) { ActivityView() }
            }
            Tab("Profile", systemImage: "person.crop.circle", value: AppTab.profile) {
                TabRoot(path: $router.profilePath) { ProfileView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Milestone 7: shared groups stay current while the app is active, and only then.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { environment.sharedGroups.startSync() } else { environment.sharedGroups.stopSync() }
        }
        // The sign-in stopped working while the app was open: back to sign-in, with an explanation.
        .onChange(of: environment.sharedGroups.accountState) { _, state in
            if state == .sessionEnded { Task { await auth?.sessionEnded() } }
        }
        // Milestone 7: a sheet for a shared group's expense, receipt, or settings runs on that group's ledger.
        .sheet(item: $router.composer) { request in
            ComposerEntryView(request: request)
                .environment(environment.environment(for: request.groupID ?? request.editingExpenseID.flatMap(environment.sharedGroups.groupID(containing:))))
        }
        .fullScreenCover(item: $router.receiptFlow) { request in
            ReceiptFlowView(request: request)
                .environment(receiptEnvironment(for: request))
        }
        .sheet(item: $router.groupEditor) { request in
            GroupEditorView(request: request)
                .environment(environment.environment(for: request.groupID))
        }
        .sheet(item: Binding(get: { environment.sharing.pendingInvitation }, set: { environment.sharing.pendingInvitation = $0 })) { invitation in
            JoinRoomView(invitation: invitation.key) { roomID in router.openSharedRoom(roomID) }
        }
        .sheet(item: Binding(get: { environment.sharedGroups.pendingInvitation }, set: { environment.sharedGroups.pendingInvitation = $0 })) { invitation in
            JoinGroupView(initialCode: invitation.code) { groupID in router.openGroupAfterSheet(groupID) }
        }
        .sheet(item: Binding(get: { session?.legacyOffer }, set: { if $0 == nil { session?.postponeLegacyOffer() } })) { offer in
            LegacyDataSheet(offer: offer)
        }
    }

    private func receiptEnvironment(for request: ReceiptFlowRequest) -> AppEnvironment {
        switch request.start {
        case .new(let groupID): environment.environment(for: groupID)
        case .resume(let roomID): environment.environment(for: environment.sharedGroups.groupID(holdingRoom: roomID))
        case .groupReceipt(let groupID, _): environment.environment(for: groupID)
        }
    }
}

/// A tab's navigation stack with the shared destinations and zoom-transition namespace.
///
/// Milestone 7: each destination runs on the ledger of the group it belongs to — a shared group's
/// server-backed ledger, or this iPhone's own — so the same screens serve both.
private struct TabRoot<Content: View>: View {
    @Binding var path: [AppRoute]
    @ViewBuilder var content: Content
    @Namespace private var namespace
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: AppRoute.self) { route in
                    destination(route)
                        .environment(environment(for: route))
                }
        }
        .environment(\.groupTransitionNamespace, namespace)
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .group(let id):
            GroupDetailView(groupID: id)
                .navigationTransition(.zoom(sourceID: id, in: namespace))
        case .settlePlan(let id):
            SettlementPlanView(groupID: id)
        case .expense(let id):
            ExpenseDetailView(expenseID: id)
        case .pay(let groupID, let recipientID):
            PayingView(groupID: groupID, recipientID: recipientID)
        case .paymentAttempt(let id):
            PaymentAttemptView(attemptID: id)
        case .paymentProfile:
            PaymentProfileView()
        }
    }

    private func environment(for route: AppRoute) -> AppEnvironment {
        let groups = environment.sharedGroups
        switch route {
        case .group(let id), .settlePlan(let id), .pay(let id, _):
            return environment.environment(for: id)
        case .expense(let id):
            return environment.environment(for: groups.groupID(containing: id))
        case .paymentAttempt(let id):
            return environment.environment(for: groups.groupID(containingAttempt: id))
        case .paymentProfile:
            // Signed in: payment methods live on the server profile and every shared group reads them there.
            guard groups.isReady else { return environment.local }
            return AppEnvironment(ledger: ProfileDestinationsLedger(service: groups), connectivity: environment.connectivity,
                                  haptics: environment.haptics, quickEntry: environment.quickEntry, handoff: environment.handoff,
                                  receipts: environment.receipts, configuration: environment.configuration, sharing: environment.sharing,
                                  sharedGroups: groups, rootLedger: environment.rootLedger)
        }
    }
}

#Preview("App · standard") {
    RootView()
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
        .squareUpTheme()
}

#Preview("App · new user") {
    RootView()
        .environment(AppEnvironment.preview(.newUser))
        .environment(AppRouter())
        .squareUpTheme()
}
