import SwiftUI

/// Which expenses produced one member's balance (milestone 2 §5 "inspect every member's position").
struct BalanceExplanationSheet: View {
    let summary: GroupDetailSummary
    let member: Member
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: SUSpacing.sm) {
                        SUAvatar(member: member, size: .large, isCurrentUser: member.id == summary.currentUserID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName).font(SUFont.cardTitle)
                            Text(netSentence).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .suListRows()
                Section {
                    let rows = summary.contributions(for: member.id, expenses: summary.activeExpenses)
                    if rows.isEmpty {
                        Text(String(localized: "No expenses affect this balance.")).foregroundStyle(SUColor.textSecondary)
                    }
                    ForEach(rows, id: \.expense.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.expense.title).font(SUFont.body)
                                Text(row.effect.isPositive ? String(localized: "paid more than their share") : String(localized: "their share"))
                                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            }
                            Spacer()
                            SUAmountView(money: row.effect.magnitude, direction: row.effect.isPositive ? .incoming : .outgoing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    let settlements = summary.activity.filter { entry in
                        if case .settlement = entry.kind { return entry.actorID == member.id || entry.title.contains(member.firstName) }
                        return false
                    }
                    if !settlements.isEmpty {
                        Text(String(localized: "Confirmed payments also count toward this balance — see Activity."))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                } header: {
                    Text("Contributing expenses")
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Balance details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var netSentence: String {
        let net = summary.plan.confirmedNet(for: member.id)
        let amount = MoneyFormatting.string(net.magnitude)
        if net.isPositive { return String(localized: "Is owed \(amount) overall") }
        if net.isNegative { return String(localized: "Owes \(amount) overall") }
        return String(localized: "Settled up")
    }
}

/// A tombstoned expense: struck through, labelled, and attributed.
struct DeletedExpenseRow: View {
    let expense: Expense
    let members: [MemberID: Member]
    let currentUserID: MemberID
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.push(.expense(expense.id))
        } label: {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SUColor.textTertiary)
                    .frame(width: 40, height: 40)
                    .suSurface(SUShape.control, elevated: true)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(expense.title)
                        .font(SUFont.cardTitle)
                        .strikethrough()
                        .foregroundStyle(SUColor.textSecondary)
                    Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                }
                Spacer(minLength: SUSpacing.xs)
                SUAmountView(money: expense.total, direction: .muted, style: .small)
                    .strikethrough()
            }
            .padding(.vertical, SUSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Deleted: \(expense.title), \(MoneyFormatting.spokenString(expense.total)). \(detail)"))
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
        let who = expense.deletedBy.map { $0 == currentUserID ? String(localized: "you") : (members[$0]?.displayName ?? "") } ?? ""
        let when = expense.deletedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return String(localized: "Deleted by \(who) · \(when)")
    }
}

/// Ledger rows in a panel, under an optional title.
struct ActivityList: View {
    var title: String?
    let entries: [ActivityEntry]
    let members: [MemberID: Member]
    var showsGroup = false

    var body: some View {
        if let title {
            SUPanelSection(title: title) { rows }
        } else {
            SUCard(padding: SUSpacing.sm + 2) { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if entries.isEmpty {
            Text(String(localized: "Nothing here yet."))
                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    ActivityRowLink(entry: entry, members: members, showsGroup: showsGroup)
                    if entry.id != entries.last?.id { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                }
            }
        }
    }
}

/// A ledger row that opens its expense or payment when there is one to open.
struct ActivityRowLink: View {
    let entry: ActivityEntry
    let members: [MemberID: Member]
    var showsGroup = false
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let route {
            Button { router.push(route) } label: {
                SUTransactionRow(entry: entry, members: members, showsGroup: showsGroup)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
        } else {
            SUTransactionRow(entry: entry, members: members, showsGroup: showsGroup)
        }
    }

    private var route: AppRoute? {
        switch entry.kind {
        case .expense(let id): .expense(id)
        case .settlement, .event: nil
        }
    }
}
