import SwiftUI

/// "Add expense" without a group (Home, the tab bar's +). The composer lists only this iPhone's
/// groups, so when there are shared groups this asks first which group it's for — one tap — and
/// then opens the composer in that group, on its own ledger. With only groups on this iPhone (or
/// when editing), the composer opens directly, as before.
struct ComposerEntryView: View {
    let request: ComposerRequest
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: GroupID?
    @State private var localGroups: [ExpenseGroup]?

    private var sharedGroups: [GroupSummaryDTO] {
        environment.sharedGroups.summaries.filter { $0.group.archivedAt == nil }
    }

    var body: some View {
        if let groupID = request.groupID ?? chosen {
            ComposeExpenseView(request: ComposerRequest(groupID: groupID, mode: request.mode, editingExpenseID: request.editingExpenseID))
                .environment(environment.environment(for: groupID))
        } else if request.editingExpenseID != nil || sharedGroups.isEmpty {
            ComposeExpenseView(request: request)
        } else {
            picker
        }
    }

    private var picker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    SUHeadline(primary: String(localized: "Add an expense"), secondary: String(localized: "Which group is it for?"))
                    SUPanelSection(title: String(localized: "Your groups")) {
                        VStack(spacing: 0) {
                            ForEach(sharedGroups, id: \.group.id) { summary in
                                if let id = GroupID(string: summary.group.id) {
                                    row(name: summary.group.name, symbol: summary.group.symbol,
                                        detail: Inflect.string("^[\(summary.memberCount) member](inflect: true)"), id: id)
                                }
                            }
                            ForEach(localGroups ?? []) { group in
                                row(name: group.name, symbol: group.symbolName, detail: String(localized: "On this iPhone"), id: group.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.lg)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Add expense"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .task {
                guard localGroups == nil else { return }
                localGroups = (try? await environment.ledger.snapshot())?.groupsForCurrentUser ?? []
            }
        }
        .accessibilityIdentifier("composer.chooseGroup")
    }

    private func row(name: String, symbol: String, detail: String, id: GroupID) -> some View {
        Button {
            chosen = id
        } label: {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: symbol).font(.title3).foregroundStyle(SUColor.textPrimary)
                    .frame(width: 40, height: 40).background(SUColor.glassFillElevated, in: SUShape.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.suPressable)
        .accessibilityIdentifier("composer.group.\(name)")
    }
}
