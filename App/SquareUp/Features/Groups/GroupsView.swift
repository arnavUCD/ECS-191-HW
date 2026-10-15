import SwiftUI

/// All of the person's groups, with their position in each.
struct GroupsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        GroupsScreen(environment: environment)
    }
}

private struct GroupsScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<[GroupListItem]>
    /// Milestone 7: groups shared with other people's iPhones (server-backed).
    @State private var sharedItems: [GroupListItem] = []
    @State private var isJoining = false
    @State private var query = ""
    @Environment(AppRouter.self) private var router
    @Environment(\.groupTransitionNamespace) private var namespace

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger, derive: GroupSummaryBuilder.listItems))
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "Groups"))
            .toolbar {
                if environment.sharedGroups.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Join with a code"), systemImage: "ticket") { isJoining = true }
                            .accessibilityIdentifier("groups.join")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "New group"), systemImage: "plus") {
                        router.groupEditor = .create
                    }
                    .accessibilityIdentifier("groups.new")
                }
            }
            .task(id: environment.ledger.revision) { await model.load() }
            .task(id: environment.sharedGroups.version) { await loadShared() }
            .task { await environment.sharedGroups.refreshGroups() }
            .refreshable {
                await environment.sharedGroups.refreshGroups()
                await model.load()
                await loadShared()
            }
            .sheet(isPresented: $isJoining) {
                JoinGroupView(initialCode: nil) { groupID in router.openGroupAfterSheet(groupID) }
            }
    }

    private func loadShared() async {
        let workspaces = await environment.sharedGroups.workspaces()
        sharedItems = workspaces.flatMap { GroupSummaryBuilder.listItems(from: $0) }
            .sorted { $0.group.name.localizedStandardCompare($1.group.name) == .orderedAscending }
    }

    private var sharedIDs: Set<GroupID> { Set(sharedItems.map(\.group.id)) }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { SULoadingState(cardCount: 4).padding(SUSpacing.screenMargin) }
                .suScreenBackground()
        case .failed:
            SUErrorState(
                title: String(localized: "Couldn't load groups"),
                message: String(localized: "Nothing was changed. Try again.")
            ) { Task { await model.load() } }
                .frame(maxHeight: .infinity)
                .suScreenBackground()
        case .loaded(let items) where items.isEmpty && sharedItems.isEmpty && environment.sharedGroups.receivedInvitations.isEmpty:
            SUEmptyState(
                systemImage: "person.3.sequence.fill",
                title: String(localized: "No groups yet"),
                message: String(localized: "Create a group for your apartment, a trip, or a dinner crew."),
                primaryTitle: String(localized: "Create a group"),
                primaryAction: { router.groupEditor = .create }
            )
            .frame(maxHeight: .infinity)
            .suScreenBackground()
        case .loaded(let items):
            list(filtered(items.filter { !sharedIDs.contains($0.group.id) }))
        }
    }

    private func filtered(_ items: [GroupListItem]) -> [GroupListItem] {
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.group.name.localizedStandardContains(query)
                || item.members.contains { $0.displayName.localizedStandardContains(query) }
        }
    }

    private func list(_ items: [GroupListItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SUSpacing.sm) {
                if environment.sharedGroups.isConfigured {
                    ReceivedInvitationsSection()
                    sharedSection
                    SUSectionHeader(title: String(localized: "On this iPhone"))
                        .padding(.top, SUSpacing.sm)
                }
                ForEach(items) { row($0) }
                if items.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xxl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $query, prompt: Text("Groups or people"))
        .suScreenBackground()
    }

    @ViewBuilder
    private var sharedSection: some View {
        let groups = environment.sharedGroups
        SUSectionHeader(title: String(localized: "Shared groups"), subtitle: sharedSubtitle)
        if sharedItems.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(groups.isReady
                    ? String(localized: "No shared groups yet. Create one, share a group from this iPhone, or join with an invitation code.")
                    : String(localized: "Sign in from Profile to share groups with other people's iPhones. Groups on this iPhone work without an account."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Join with a code")) { isJoining = true }
                    .font(SUFont.supporting.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("groups.sharedEmpty")
        } else {
            ForEach(filtered(sharedItems)) { item in row(item, isShared: true) }
        }
    }

    private var sharedSubtitle: String? {
        switch environment.sharedGroups.listState {
        case .offline: String(localized: "Offline · showing the copies saved on this iPhone")
        // Refreshing the list shows nothing extra, so the page doesn't jump while it checks.
        default: nil
        }
    }

    private func row(_ item: GroupListItem, isShared: Bool = false) -> some View {
        NavigationLink(value: AppRoute.group(item.group.id)) {
            GroupRow(item: item, isShared: isShared)
        }
        .buttonStyle(.suPressable)
        .modifier(GroupTransitionSource(id: item.group.id, namespace: namespace))
        .accessibilityIdentifier("groups.row.\(item.group.name)")
    }
}

struct GroupTransitionSource: ViewModifier {
    let id: GroupID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// A group as a list card: a small cover pressed with the group's symbol (and its head count),
/// then its people, your position, and its name.
private struct GroupRow: View {
    let item: GroupListItem
    var isShared = false
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 88
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var coverShape: RoundedRectangle { RoundedRectangle(cornerRadius: SURadius.panel - 14, style: .continuous) }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SUSpacing.md))
        layout {
            cover
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                HStack(alignment: .center, spacing: SUSpacing.xs) {
                    SUAvatarStack(members: item.members, currentUserID: item.currentUserID)
                    Spacer(minLength: SUSpacing.xs)
                    position
                }
                Text(item.group.name)
                    .font(SUFont.cardTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SUSpacing.xs)
        .padding(.trailing, SUSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SUBevel(shape: RoundedRectangle(cornerRadius: SURadius.panel - 6, style: .continuous)) }
        .contentShape(RoundedRectangle(cornerRadius: SURadius.panel - 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        ZStack {
            SUCoverArt(palette: palette, focus: UnitPoint(x: 0.72, y: 0.28), halftoneSpacing: 7)
            Image(systemName: item.group.symbolName)
                .font(.system(size: coverSide * 0.34, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(coverShape)
        .overlay { coverShape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        .overlay(alignment: .topLeading) {
            Label("\(item.members.count)", systemImage: "person.fill")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .glassEffect(.regular, in: Capsule())
                .padding(6)
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var palette: SUMeshBackground.Palette {
        if item.yourNet.isPositive { return .positive }
        if item.yourNet.isNegative { return .attention }
        return .calm
    }

    private var detail: String {
        let base = item.group.details ?? Inflect.string("^[\(item.members.count) member](inflect: true)")
        return isShared ? "\(String(localized: "Shared")) · \(base)" : base
    }

    @ViewBuilder
    private var position: some View {
        if item.yourNet.isPositive {
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(localized: "you're owed")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                SUAmountView(money: item.yourNet, direction: .incoming)
            }
        } else if item.yourNet.isNegative {
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(localized: "you owe")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                SUAmountView(money: item.yourNet.magnitude, direction: .outgoing)
            }
        } else {
            SUStatusChip.settled
        }
    }
}

#Preview("Groups") {
    NavigationStack { GroupsView() }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}

#Preview("Groups · empty") {
    NavigationStack { GroupsView() }
        .environment(AppEnvironment.preview(.newUser))
        .environment(AppRouter())
}
