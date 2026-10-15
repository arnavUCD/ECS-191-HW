import SwiftUI

/// The center of the personal experience (milestone 2 §7): identity, your position, a persistent
/// Add Expense action, Settle Up when anything is unresolved, and Expenses / Balances / Activity.
struct GroupDetailView: View {
    let groupID: GroupID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        GroupDetailScreen(groupID: groupID, environment: environment)
    }
}

private nonisolated enum GroupDetailSegment: String, CaseIterable, Identifiable, Sendable {
    case expenses, balances, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .balances: String(localized: "Balances")
        case .expenses: String(localized: "Expenses")
        case .activity: String(localized: "Activity")
        }
    }

    var symbolName: String {
        switch self {
        case .balances: "scalemass"
        case .expenses: "receipt"
        case .activity: "clock"
        }
    }
}

private struct GroupDetailScreen: View {
    let groupID: GroupID
    let environment: AppEnvironment
    @State private var model: SnapshotModel<GroupDetailSummary>
    @State private var segment: GroupDetailSegment = .expenses
    @State private var isShowingPeople = false
    @State private var isPublishing = false
    @Environment(AppRouter.self) private var router

    /// Milestone 7: this group's server-backed ledger when it is a shared group.
    private var shared: SharedGroupLedger? {
        environment.sharedGroup?.groupID == groupID ? environment.sharedGroup : nil
    }

    init(groupID: GroupID, environment: AppEnvironment) {
        self.groupID = groupID
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger) { snapshot in
            try GroupSummaryBuilder.detail(for: groupID, in: snapshot)
        })
    }

    var body: some View {
        content
            .navigationTitle(model.value?.group.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let group = model.value?.group {
                    if shared != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "People"), systemImage: "person.2") { isShowingPeople = true }
                                .accessibilityIdentifier("group.people")
                        }
                    }
                    // In a shared group only the owner edits the details (§3.2).
                    if shared.map({ $0.isOwner && !$0.isArchived }) ?? true {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Edit group"), systemImage: "pencil") {
                                router.groupEditor = .edit(group.id)
                            }
                            .accessibilityIdentifier("group.edit")
                        }
                    }
                }
            }
            .task(id: environment.ledger.revision) { await model.load() }
            .sharedGroupSync(shared)
            .sheet(isPresented: $isShowingPeople) {
                if let shared, let summary = model.value {
                    NavigationStack {
                        ScrollView {
                            SharedGroupMembersSection(ledger: shared, summary: summary)
                                .padding(SUSpacing.screenMargin)
                                .frame(maxWidth: SUMetrics.readableWidth)
                                .frame(maxWidth: .infinity)
                        }
                        .suScreenBackground()
                        .navigationTitle(String(localized: "People"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { isShowingPeople = false } }
                        }
                    }
                    .environment(environment)
                }
            }
            .sheet(isPresented: $isPublishing) {
                if let summary = model.value {
                    PublishGroupSheet(groupID: summary.group.id, groupName: summary.group.name) { id in router.openGroupAfterSheet(id) }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { SULoadingState(cardCount: 2).padding(SUSpacing.screenMargin) }
                .suScreenBackground()
        case .failed(.groupNotFound):
            ContentUnavailableView(
                String(localized: "Group not found"),
                systemImage: "questionmark.folder",
                description: Text("It may have been removed, or you may no longer be a member.")
            )
            .suScreenBackground()
        case .failed:
            SUErrorState(
                title: String(localized: "Couldn't load this group"),
                message: String(localized: "Nothing was changed. Try again.")
            ) { Task { await model.load() } }
                .frame(maxHeight: .infinity)
                .suScreenBackground()
        case .loaded(let summary):
            loaded(summary)
        }
    }

    private func loaded(_ summary: GroupDetailSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let shared {
                    SharedGroupStatusBar(ledger: shared)
                }
                GroupHeader(summary: summary) {
                    router.showSettlePlan(summary.group.id)
                }
                if let shared {
                    SharedPeopleSummary(ledger: shared, summary: summary) { isShowingPeople = true }
                    GroupReceiptsSection(ledger: shared)
                } else if environment.sharedGroups.isConfigured {
                    ShareThisGroupCard { isPublishing = true }
                }

                SUSegmentPicker(title: String(localized: "Section"), selection: $segment, options: GroupDetailSegment.allCases) { option in
                    .init(title: option.title, systemImage: option.symbolName)
                }
                .accessibilityIdentifier("group.segments")

                Group {
                    switch segment {
                    case .balances: BalancesSection(summary: summary)
                    case .expenses: ExpensesSection(summary: summary)
                    case .activity: ActivityList(title: String(localized: "Activity"), entries: summary.activity, members: summary.memberLookup)
                    }
                }
                .id(segment)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, 96)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
            .suAnimation(.reveal, value: segment)
        }
        .suScreenBackground()
        .safeAreaInset(edge: .bottom) {
            if !(shared?.isArchived ?? false) { actionBar(summary) }
        }
    }

    private func actionBar(_ summary: GroupDetailSummary) -> some View {
        SUFloatingActionBar {
            Button {
                router.presentComposer(groupID: summary.group.id)
            } label: {
                Label(String(localized: "Add expense"), systemImage: "plus")
                    .font(SUFont.button)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .accessibilityIdentifier("group.addExpense")
            Button {
                router.presentReceiptCapture(groupID: summary.group.id)
            } label: {
                Label(String(localized: "Scan receipt"), systemImage: "doc.viewfinder")
                    .font(SUFont.button)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("group.scanReceipt")
        }
        .frame(maxWidth: SUMetrics.readableWidth)
    }
}

/// Milestone 7: who is in a shared group at a glance, with the way to people and invitations.
private struct SharedPeopleSummary: View {
    let ledger: SharedGroupLedger
    let summary: GroupDetailSummary
    let open: () -> Void

    var body: some View {
        let waiting = summary.members.filter { ledger.status(of: $0.id) == "pending" }.count
        Button(action: open) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: "person.2.circle").font(.title2).foregroundStyle(SUColor.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Shared group")).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    Text(waiting > 0
                        ? Inflect.string("^[\(waiting) person](inflect: true) waiting to join · Everyone sees the same expenses")
                        : String(localized: "Everyone sees the same expenses and balances"))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary).accessibilityHidden(true)
            }
            .padding(SUSpacing.md)
            .frame(minHeight: 44)
            .suSurface(SUShape.compact)
        }
        .buttonStyle(.suPressable)
        .accessibilityHint(String(localized: "Shows people and invitations"))
        .accessibilityIdentifier("group.sharedPeople")
    }
}

/// Milestone 7: the way to share a local group (never automatic).
private struct ShareThisGroupCard: View {
    let share: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SUSpacing.sm) {
            Image(systemName: "person.2.badge.gearshape").font(.title3).foregroundStyle(SUColor.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(String(localized: "On this iPhone only")).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                Text(String(localized: "Share it so everyone sees the same expenses on their own iPhone and can settle up with you."))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Share this group…"), action: share)
                    .font(SUFont.supporting.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("group.share")
            }
        }
        .padding(SUSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .suSurface(SUShape.compact)
        .accessibilityElement(children: .contain)
    }
}

/// The group at a glance, in one calm card: its mark and name, the facts in one line, where you
/// stand (one colour, sign to cents), what it takes to settle, and Settle up while anything is open.
private struct GroupHeader: View {
    let summary: GroupDetailSummary
    let settleUp: () -> Void

    var body: some View {
        SUCard(padding: SUSpacing.md + 2) {
            VStack(alignment: .leading, spacing: SUSpacing.md) {
                HStack(alignment: .center, spacing: SUSpacing.sm) {
                    SUGroupMark(group: summary.group, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.group.name)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(SUColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(facts)
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let details = summary.group.details {
                    Text(details)
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(SUColor.hairline)
                VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                    Text(positionText)
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)
                    if summary.yourNet.isZero {
                        SUStatusChip.settled
                    } else {
                        SUAmountView(money: summary.yourNet.magnitude, direction: summary.yourNet.isPositive ? .incoming : .outgoing,
                                     style: .large)
                    }
                    if let planText {
                        Text(planText)
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group.position")
                if !summary.plan.isSettled {
                    Button(action: settleUp) {
                        Label(String(localized: "Settle up"), systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.suPrimary)
                    .accessibilityIdentifier("group.settleUp")
                    .accessibilityHint(String(localized: "Shows who pays whom to make the group square"))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group.header")
    }

    /// "3 members · 3 expenses · $348.77"
    private var facts: String {
        [
            Inflect.string("^[\(summary.activeMembers.count) member](inflect: true)"),
            Inflect.string("^[\(summary.recordedExpenses.count) expense](inflect: true)"),
            MoneyFormatting.string(summary.totalSpent),
        ].joined(separator: " · ")
    }

    /// What it takes to make the group square, when anything is open.
    private var planText: String? {
        let plan = summary.plan
        if plan.payments.isEmpty, !plan.pending.isEmpty {
            return Inflect.string("^[\(plan.pending.count) payment](inflect: true) awaiting confirmation")
        }
        if plan.payments.isEmpty { return nil }
        return Inflect.string("^[\(plan.payments.count) payment](inflect: true) to settle up")
    }

    private var positionText: String {
        if summary.yourNet.isPositive { return String(localized: "In this group, you're owed") }
        if summary.yourNet.isNegative { return String(localized: "In this group, you owe") }
        return String(localized: "In this group, you're all square")
    }
}

private struct BalancesSection: View {
    let summary: GroupDetailSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var explainedMember: Member?
    @State private var toggleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            SUPanelSection(title: String(localized: "Between you and others")) {
                if summary.relationships.isEmpty {
                    Label(String(localized: "You don't owe anyone here, and nobody owes you."), systemImage: "checkmark.seal")
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(summary.relationships) { relationship in
                            RelationshipRow(relationship: relationship, labels: labels)
                            if relationship.id != summary.relationships.last?.id { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                        }
                    }
                }
            }

            simplificationCard

            SUPanelSection(title: String(localized: "Everyone"), subtitle: String(localized: "Tap a person to see which expenses created their balance")) {
                VStack(spacing: 0) {
                    ForEach(summary.memberBalances) { balance in
                        Button {
                            explainedMember = balance.member
                        } label: {
                            MemberBalanceRow(
                                balance: balance,
                                isCurrentUser: balance.member.id == summary.currentUserID,
                                isFormer: !summary.group.isActiveMember(balance.member.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "Shows the expenses behind this balance"))
                        if balance.id != summary.memberBalances.last?.id { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                    }
                }
            }
        }
        .sheet(item: $explainedMember) { member in
            BalanceExplanationSheet(summary: summary, member: member)
        }
    }

    private var simplificationCard: some View {
        let plan = summary.plan
        return SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Toggle(isOn: Binding(
                    get: { summary.group.simplifiesDebts },
                    set: { enabled in
                        Task {
                            do {
                                try await environment.ledger.setSimplification(enabled, for: summary.group.id)
                                toggleError = nil
                            } catch {
                                toggleError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Simplify payments")).font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary)
                        Text(PlanLanguage.countSummary(plan))
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
                .tint(SUColor.accent)
                .accessibilityIdentifier("balances.simplify")
                Text(String(localized: "Simplifying changes who pays whom. It never changes how much anyone owes or is owed overall."))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                if let toggleError {
                    Label(toggleError, systemImage: "exclamationmark.circle").font(SUFont.metadata).foregroundStyle(SUColor.negative)
                }
                if !plan.isSettled {
                    Button {
                        router.showSettlePlan(summary.group.id)
                    } label: {
                        Text(String(localized: "See who pays whom"))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.suSecondary)
                    .accessibilityIdentifier("balances.seePlan")
                }
            }
        }
    }

    private var labels: [MemberID: String] { PersonIdentity.shortLabels(for: summary.members) }
}

private struct RelationshipRow: View {
    let relationship: Relationship
    let labels: [MemberID: String]

    var body: some View {
        HStack(spacing: SUSpacing.sm) {
            SUAvatar(member: relationship.member, size: .medium)
            Text(sentence)
                .font(SUFont.body)
                .foregroundStyle(SUColor.textPrimary)
            Spacer(minLength: SUSpacing.xs)
            SUAmountView(
                money: relationship.amount.magnitude,
                direction: relationship.amount.isPositive ? .incoming : .outgoing
            )
        }
        .padding(.vertical, SUSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        let name = labels[relationship.member.id] ?? relationship.member.displayName
        return relationship.amount.isPositive
            ? String(localized: "\(name) owes you")
            : String(localized: "You owe \(name)")
    }
}

private struct MemberBalanceRow: View {
    let balance: MemberBalance
    let isCurrentUser: Bool
    var isFormer = false

    var body: some View {
        HStack(spacing: SUSpacing.sm) {
            SUAvatar(member: balance.member, size: .medium, isCurrentUser: isCurrentUser)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SUSpacing.xs) {
                    Text(balance.member.displayName)
                        .font(SUFont.body.weight(.semibold))
                        .foregroundStyle(SUColor.textPrimary)
                    if isCurrentUser { SURoleBadge(kind: .you) }
                }
                if isFormer {
                    Text(String(localized: "Former member")).font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                }
            }
            Spacer(minLength: SUSpacing.xs)
            VStack(alignment: .trailing, spacing: 0) {
                Text(caption).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                if !balance.net.isZero {
                    SUAmountView(money: balance.net.magnitude, direction: balance.net.isPositive ? .incoming : .outgoing, style: .small)
                }
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SUSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        if balance.net.isPositive { return String(localized: "is owed") }
        if balance.net.isNegative { return String(localized: "owes") }
        return String(localized: "settled up")
    }
}

private struct ExpensesSection: View {
    let summary: GroupDetailSummary
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment

    /// Milestone 7: expenses shown before the server confirmed them, marked so they never look saved.
    private var pendingTitles: [String] {
        guard let shared = environment.sharedGroup, !shared.pendingExpenseIDs.isEmpty else { return [] }
        return summary.activeExpenses.filter { shared.pendingExpenseIDs.contains($0.id) }.map(\.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            if !pendingTitles.isEmpty {
                Label {
                    Text(environment.sharedGroup?.unsent.isEmpty == false
                        ? String(localized: "Not saved yet — waiting for connection: \(pendingTitles.formatted(.list(type: .and)))")
                        : String(localized: "Sending: \(pendingTitles.formatted(.list(type: .and)))"))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(SUColor.warning)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group.pendingExpenses")
            }
            if !summary.unfinishedRooms.isEmpty {
                VStack(alignment: .leading, spacing: SUSpacing.sm) {
                    SUSectionHeader(title: String(localized: "Receipts in progress"),
                                    subtitle: String(localized: "Not expenses yet. Finish claiming to save them."))
                    ForEach(summary.unfinishedRooms) { room in
                        UnfinishedReceiptRow(room: room, groupName: nil) { router.openReceipt(room.id) }
                    }
                }
            }
            if summary.recordedExpenses.isEmpty {
                SUPanelSection(title: String(localized: "Expenses")) {
                    Text(String(localized: "No expenses yet. Add the first one below."))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                }
            } else {
                ActivityList(title: String(localized: "Expenses"), entries: summary.recordedExpenses, members: summary.memberLookup, showsGroup: false)
            }
            if !summary.deletedExpenses.isEmpty {
                VStack(alignment: .leading, spacing: SUSpacing.sm) {
                    SUSectionHeader(title: String(localized: "Deleted"), subtitle: String(localized: "Kept for history. They don't affect balances."))
                    SUCard(padding: SUSpacing.sm + 2) {
                        VStack(spacing: 0) {
                            ForEach(summary.deletedExpenses) { expense in
                                DeletedExpenseRow(expense: expense, members: summary.memberLookup, currentUserID: summary.currentUserID)
                                if expense.id != summary.deletedExpenses.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview("Group · coastal trip") {
    NavigationStack { GroupDetailView(groupID: SampleLedger.GroupKey.coastal.id) }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}

#Preview("Group · personal") {
    NavigationStack { GroupDetailView(groupID: SampleLedger.GroupKey.tahoe.id) }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
