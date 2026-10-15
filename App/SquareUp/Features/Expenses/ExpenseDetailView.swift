import SwiftUI

/// Full expense detail (milestone 2 §7–8): who paid, who shares it, how it affects you, its
/// revision history, and Edit / Delete with an explained balance impact and immediate undo.
struct ExpenseDetailView: View {
    let expenseID: ExpenseID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ExpenseDetailScreen(expenseID: expenseID, environment: environment)
    }
}

private struct ExpenseDetailScreen: View {
    let expenseID: ExpenseID
    let environment: AppEnvironment
    @State private var model: SnapshotModel<ExpenseDetailSummary>
    @State private var isConfirmingDelete = false
    @State private var actionError: String?
    @State private var showsUndo = false
    @State private var deleteCount = 0
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    init(expenseID: ExpenseID, environment: AppEnvironment) {
        self.expenseID = expenseID
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger) { try ExpenseDetailSummary.make(expenseID: expenseID, from: $0) })
    }

    var body: some View {
        content
            .navigationTitle(model.value?.expense.title ?? String(localized: "Expense"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: environment.ledger.revision) { await model.load() }
            .sensoryFeedback(.warning, trigger: deleteCount)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).suScreenBackground()
        case .failed(let error):
            SUErrorState(title: String(localized: "Couldn't open this expense"), message: LedgerErrorMessages.text(for: error)) {
                Task { await model.load() }
            }
            .frame(maxHeight: .infinity)
            .suScreenBackground()
        case .loaded(let summary):
            loaded(summary)
        }
    }

    private func loaded(_ summary: ExpenseDetailSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if summary.expense.isDeleted {
                    deletedBanner(summary)
                }
                if let actionError {
                    SUConfirmationBanner(title: String(localized: "Not changed"), message: actionError,
                                         systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                header(summary)
                paidBy(summary)
                split(summary)
                if let room = summary.receiptRoom {
                    ItemizedReceiptSection(room: room, expense: summary.expense, members: summary.members, currentUserID: summary.currentUserID)
                }
                historySection(summary)
                if !summary.expense.isDeleted, permissions(summary).canDelete {
                    Button(String(localized: "Delete expense"), systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .buttonStyle(.suDestructive)
                    .accessibilityIdentifier("expense.delete")
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xxl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .confirmationDialog(
            String(localized: "Delete \(summary.expense.title)?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete expense"), role: .destructive) { delete() }
        } message: {
            Text(deletionMessage(summary))
        }
    }

    /// The expense on a cover pressed with its category: the category readout on top, the people
    /// who share it at the foot, then the title, figure, and what it means for you beneath.
    private func header(_ summary: ExpenseDetailSummary) -> some View {
        let expense = summary.expense
        let effect = summary.yourEffect
        let sharers = expense.allocations.compactMap { summary.members[$0.memberID] }
        return SUCoverPanel(palette: expense.isDeleted ? .calm : (effect.isPositive ? .positive : (effect.isNegative ? .attention : .calm)),
                            symbol: expense.category.symbolName, coverHeight: 190) {
            SUCoverChip(lead: .symbol(expense.category.symbolName, expense.category.color), title: expense.category.label, subtitle: summary.group.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SUAvatarCluster(members: sharers, currentUserID: summary.currentUserID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            SUTagPill(title: expense.date.formatted(.dateTime.month(.abbreviated).day()), systemImage: "calendar")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        } content: {
            VStack(spacing: SUSpacing.xs) {
                Text(expense.title)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .strikethrough(expense.isDeleted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(summary.group.name) · \(expense.category.label) · \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    .multilineTextAlignment(.center)
                SUAmountView(money: expense.total, direction: expense.isDeleted ? .muted : .neutral, style: .hero,
                             emphasizesWholeUnits: !expense.isDeleted)
                    .padding(.top, SUSpacing.xs)
                if !expense.isDeleted {
                    Label(effectSentence(effect), systemImage: effect.isPositive ? "arrow.down.left" : (effect.isNegative ? "arrow.up.right" : "equal"))
                        .font(SUFont.supporting.weight(.semibold))
                        .foregroundStyle(effect.isPositive ? SUColor.positive : (effect.isNegative ? SUColor.negative : SUColor.textSecondary))
                        .padding(.horizontal, SUSpacing.sm)
                        .frame(minHeight: 32)
                        .background((effect.isPositive ? SUColor.positive : (effect.isNegative ? SUColor.negative : SUColor.textSecondary)).opacity(0.12),
                                    in: Capsule())
                }
                if expense.revision > 1, let updatedBy = expense.updatedBy {
                    Label(String(localized: "Edited · revision \(expense.revision) · last by \(name(updatedBy, summary))"), systemImage: "pencil")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        .padding(.top, SUSpacing.xxs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func paidBy(_ summary: ExpenseDetailSummary) -> some View {
        SUPanelSection(title: String(localized: "Paid by")) {
            VStack(spacing: 0) {
                ForEach(summary.expense.payments, id: \.memberID) { share in
                    personRow(share, summary, caption: String(localized: "paid"))
                    if share.memberID != summary.expense.payments.last?.memberID { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                }
            }
        }
    }

    private func split(_ summary: ExpenseDetailSummary) -> some View {
        SUPanelSection(title: String(localized: "Split"), subtitle: summary.expense.splitMethod.label) {
            VStack(spacing: 0) {
                ForEach(summary.expense.allocations, id: \.memberID) { share in
                    personRow(share, summary, caption: String(localized: "share"))
                    if share.memberID != summary.expense.allocations.last?.memberID { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                }
            }
        }
    }

    private func personRow(_ share: Share, _ summary: ExpenseDetailSummary, caption: String) -> some View {
        HStack(spacing: SUSpacing.sm) {
            if let member = summary.members[share.memberID] {
                SUAvatar(member: member, size: .medium, isCurrentUser: member.id == summary.currentUserID)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name(share.memberID, summary, capitalized: true)).font(SUFont.body.weight(.semibold))
                Text(caption).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
            Spacer()
            SUAmountView(money: share.amount)
        }
        .padding(.vertical, SUSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func historySection(_ summary: ExpenseDetailSummary) -> some View {
        SUPanelSection(title: String(localized: "History")) {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                if summary.history.isEmpty {
                    Text(String(localized: "Added before history was recorded.")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                ForEach(summary.history) { event in
                    let description = AuditEventPresenter.describe(event, members: summary.members, currentUserID: summary.currentUserID)
                    HStack(alignment: .top, spacing: SUSpacing.sm) {
                        Image(systemName: description.symbolName)
                            .foregroundStyle(SUTransactionRow.color(for: description.tone))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(description.title).font(SUFont.supporting.weight(.semibold))
                            if let detail = description.detail {
                                Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            }
                            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                .font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expense.history")
    }

    private func permissions(_ summary: ExpenseDetailSummary) -> ExpensePermissions {
        guard let shared = environment.sharedGroups.ledger(for: summary.group.id) else { return .local }
        return .shared(summary.expense, viewer: summary.currentUserID, isOwner: shared.isOwner, isArchived: shared.isArchived)
    }

    private func deletedBanner(_ summary: ExpenseDetailSummary) -> some View {
        SUConfirmationBanner(
            title: String(localized: "Deleted"),
            message: String(localized: "This expense no longer affects balances. Its record and history are kept."),
            systemImage: "trash",
            tone: .neutral,
            actionTitle: permissions(summary).canDelete ? (showsUndo ? String(localized: "Undo") : String(localized: "Restore")) : nil
        ) {
            Task {
                do {
                    try await environment.ledger.restore(summary.expense.id)
                    showsUndo = false
                    actionError = nil
                } catch {
                    actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: summary.members)
                }
            }
        }
        .accessibilityIdentifier("expense.deletedBanner")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let summary = model.value, !summary.expense.isDeleted, permissions(summary).canEdit {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Edit")) {
                    router.presentComposer(editing: summary.expense.id)
                }
                .accessibilityIdentifier("expense.edit")
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await environment.ledger.delete(expenseID)
                showsUndo = true
                actionError = nil
                deleteCount += 1
            } catch {
                actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: model.value?.members ?? [:])
            }
        }
    }

    private func deletionMessage(_ summary: ExpenseDetailSummary) -> String {
        let lines = summary.deletionImpacts.map { impact in
            let who = name(impact.memberID, summary, capitalized: true)
            let amount = MoneyFormatting.string(impact.effect.magnitude, locale: locale)
            return impact.effect.isPositive
                ? String(localized: "\(who) will be owed \(amount) less.")
                : String(localized: "\(who) will owe \(amount) less.")
        }
        var intro = [String(localized: "It will stop affecting balances, but stays in the group's history.")]
        if permissions(summary).actsAsOwner {
            let creator = name(summary.expense.createdBy, summary, capitalized: true)
            intro.append(String(localized: "\(creator) added it. As the group's owner you can remove it; the history shows you did."))
        }
        return (intro + lines).joined(separator: "\n")
    }

    private func effectSentence(_ effect: Money) -> String {
        let amount = MoneyFormatting.string(effect.magnitude, locale: locale)
        if effect.isPositive { return String(localized: "You lent \(amount)") }
        if effect.isNegative { return String(localized: "You owe \(amount) for this") }
        return String(localized: "Doesn't change what you owe")
    }

    private func name(_ id: MemberID, _ summary: ExpenseDetailSummary, capitalized: Bool = false) -> String {
        if id == summary.currentUserID { return capitalized ? String(localized: "You") : String(localized: "you") }
        return summary.members[id]?.displayName ?? String(localized: "Someone")
    }
}

#Preview("Expense") {
    let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
    NavigationStack { ExpenseDetailView(expenseID: snapshot.expenses.first { $0.title == "Costco run" }!.id) }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
