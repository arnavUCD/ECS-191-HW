import SwiftUI

nonisolated enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case expenses
    case payments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .expenses: String(localized: "Expenses")
        case .payments: String(localized: "Payments")
        }
    }

    var symbolName: String {
        switch self {
        case .all: "square.stack"
        case .expenses: "receipt"
        case .payments: "arrow.left.arrow.right"
        }
    }

    func includes(_ entry: ActivityEntry) -> Bool {
        switch self {
        case .all: true
        case .expenses:
            switch entry.kind {
            case .expense: true
            case .settlement: false
            case .event: entry.eventCategory == .expense
            }
        case .payments:
            switch entry.kind {
            case .settlement: true
            case .expense: false
            case .event: entry.eventCategory == .payment
            }
        }
    }
}

nonisolated struct ActivityFeed: Equatable, Sendable {
    let entries: [ActivityEntry]
    let members: [MemberID: Member]

    /// Milestone 7: this iPhone's groups plus every shared group, newest first.
    static func merging(_ feeds: [ActivityFeed]) -> ActivityFeed {
        ActivityFeed(entries: feeds.flatMap(\.entries).sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id > rhs.id : lhs.date > rhs.date
        }, members: feeds.reduce(into: [:]) { result, feed in result.merge(feed.members) { first, _ in first } })
    }

    static func make(from snapshot: LedgerSnapshot) -> ActivityFeed {
        let mine = Set(snapshot.groupsForCurrentUser.map(\.id))
        return ActivityFeed(
            entries: ActivityFeedBuilder.entries(from: snapshot).filter { mine.contains($0.groupID) },
            members: snapshot.members
        )
    }
}

/// Cross-group history, grouped by day, filterable by kind.
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ActivityScreen(environment: environment)
    }
}

private struct ActivityScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<ActivityFeed>
    /// Milestone 7: activity from shared groups (each built with that group's "you").
    @State private var shared: [ActivityFeed] = []
    @State private var filter: ActivityFilter = .all
    @Environment(AppRouter.self) private var router

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger, derive: ActivityFeed.make))
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "Activity"))
            .task(id: environment.ledger.revision) { await model.load() }
            .task(id: environment.sharedGroups.version) {
                shared = await environment.sharedGroups.workspaces().map(ActivityFeed.make)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { SULoadingState(cardCount: 4).padding(SUSpacing.screenMargin) }.suScreenBackground()
        case .failed:
            SUErrorState(
                title: String(localized: "Couldn't load activity"),
                message: String(localized: "Nothing was changed. Try again.")
            ) { Task { await model.load() } }
                .frame(maxHeight: .infinity)
                .suScreenBackground()
        case .loaded(let feed):
            list(shared.isEmpty ? feed : ActivityFeed.merging([feed] + shared))
        }
    }

    private func list(_ feed: ActivityFeed) -> some View {
        let filtered = feed.entries.filter(filter.includes)
        let sections = ActivityFeedBuilder.sections(filtered, now: environment.now)
        return List {
            if sections.isEmpty {
                ContentUnavailableView(
                    String(localized: "No \(filter.title.lowercased()) yet"),
                    systemImage: filter.symbolName,
                    description: Text("Expenses and payments from your groups appear here.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        Button {
                            router.showGroup(entry.groupID)
                        } label: {
                            SUTransactionRow(entry: entry, members: feed.members)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(SUColor.glassFill)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .suScreenBackground()
        .contentMargins(.top, SUSpacing.xs, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .refreshable { await model.load() }
        .suAnimation(.reconcile, value: filter)
    }

    /// Compact floating filters on Liquid Glass (CLAUDE.md §5.1).
    private var filterBar: some View {
        SUSegmentPicker(title: String(localized: "Show"), selection: $filter, options: ActivityFilter.allCases, segment: { option in
            .init(title: option.title, systemImage: option.symbolName)
        }, fills: false)
            .contentMargins(.horizontal, SUSpacing.screenMargin, for: .scrollContent)
            .padding(.vertical, SUSpacing.xs)
    }
}

#Preview("Activity") {
    NavigationStack { ActivityView() }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
