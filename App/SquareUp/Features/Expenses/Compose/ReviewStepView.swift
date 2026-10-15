import SwiftUI

/// Step 3: a plain-language summary of exactly what will be saved, then Save.
struct ReviewStepView: View {
    let model: ComposeExpenseModel
    let save: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShared: Bool { model.groupID.map(environment.sharedGroups.isShared) ?? false }

    private var storageNote: String {
        let name = model.group?.name ?? ""
        return isShared
            ? String(localized: "Saved to the shared group. Everyone in \(name) sees it on their own iPhone.")
            : String(localized: "Saved on this iPhone. Only you see \(name) unless you share the group.")
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    summaryCard
                    if let changes = model.changeSummary {
                        changesCard(changes)
                    }
                    if let sentence = model.sentence {
                        sentenceCard(sentence)
                    }
                    breakdown
                    Label(storageNote, systemImage: isShared ? "person.2" : "lock")
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textSecondary)
                    if case .failed(let message) = model.saveState {
                        SUConfirmationBanner(
                            title: String(localized: "Not saved"),
                            message: message,
                            systemImage: "exclamationmark.triangle.fill",
                            tone: .negative
                        )
                    }
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.md)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    HStack(spacing: SUSpacing.xs) {
                        if model.saveState == .saving { ProgressView() }
                        Text(model.saveState == .saving ? String(localized: "Saving…")
                            : (model.isEditing ? String(localized: "Save changes") : String(localized: "Save expense")))
                    }
                }
                .buttonStyle(.suPrimary)
                .disabled(model.saveState == .saving || model.saveState == .saved || (model.isEditing && model.changeSummary?.hasChanges != true))
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.bottom, SUSpacing.xs)
                .frame(maxWidth: 560)
                .accessibilityIdentifier("compose.save")
            }

            if model.saveState == .saved {
                SavedConfirmation(total: model.total)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .suAnimation(.confirm, value: model.saveState)
    }

    private var summaryCard: some View {
        SUCard {
            HStack(alignment: .top, spacing: SUSpacing.sm) {
                Image(systemName: model.category.symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.category.color)
                    .frame(width: 44, height: 44)
                    .background(model.category.color.opacity(0.14), in: SUShape.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.trimmedTitle).font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary)
                    Text("\(model.group?.name ?? "") · \(model.category.label)")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Spacer(minLength: SUSpacing.xs)
                SUAmountView(money: model.total, style: .large)
            }
        }
    }

    /// The material changes of an edit, before saving (milestone 2 §8).
    private func changesCard(_ changes: ExpenseChangeSummary) -> some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Label(String(localized: "Changes"), systemImage: "pencil.circle").font(SUFont.cardTitle)
                if changes.hasChanges {
                    Text(String(localized: "Changed \(changes.fields.map(AuditEventPresenter.fieldLabel).formatted(.list(type: .and)))."))
                        .font(SUFont.supporting)
                    ForEach(changes.impacts, id: \.memberID) { impact in
                        let name = impact.memberID == model.currentUserID ? String(localized: "You")
                            : (model.members.first { $0.id == impact.memberID }?.displayName ?? "")
                        HStack {
                            Text(name).font(SUFont.supporting)
                            Spacer()
                            Text(String(localized: "\(MoneyFormatting.signedString(impact.before)) → \(MoneyFormatting.signedString(impact.after))"))
                                .font(SUFont.supporting.monospacedDigit())
                                .foregroundStyle(SUColor.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(String(localized: "The previous version stays in the expense's history."))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                } else {
                    Text(String(localized: "Nothing has changed yet.")).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.changes")
    }

    private func sentenceCard(_ sentence: ExpenseSentence) -> some View {
        SUCard(style: .elevated) {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(sentence.headline).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                Text(sentence.split).font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                Text(sentence.effect).font(SUFont.body).foregroundStyle(SUColor.textSecondary)
                if let note = sentence.roundingNote {
                    Label(note, systemImage: "plusminus.circle")
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textSecondary)
                        .padding(.top, SUSpacing.xxs)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compose.sentence")
    }

    @ViewBuilder
    private var breakdown: some View {
        if case .success(let result) = model.splitOutcome {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: String(localized: "Each person's share"))
                SUCard(padding: SUSpacing.sm + 2) {
                    VStack(spacing: 0) {
                        ForEach(result.shares.filter { !$0.amount.isZero }, id: \.memberID) { share in
                            if let member = model.members.first(where: { $0.id == share.memberID }) {
                                HStack(spacing: SUSpacing.sm) {
                                    SUAvatar(member: member, size: .medium, isCurrentUser: member.id == model.currentUserID)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.id == model.currentUserID ? String(localized: "You") : member.displayName)
                                            .font(SUFont.body.weight(.semibold))
                                            .foregroundStyle(SUColor.textPrimary)
                                        if model.payments?.contains(where: { $0.memberID == member.id }) == true { SURoleBadge(kind: .payer) }
                                    }
                                    Spacer(minLength: SUSpacing.xs)
                                    VStack(alignment: .trailing, spacing: 0) {
                                        SUAmountView(money: share.amount)
                                        if result.roundingAdjustments[member.id] != nil {
                                            Text(String(localized: "includes rounding"))
                                                .font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                                        }
                                    }
                                }
                                .padding(.vertical, SUSpacing.xs)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Success: a drawn checkmark and the saved amount. The save has already happened.
private struct SavedConfirmation: View {
    let total: Money
    @State private var drawn = false

    var body: some View {
        VStack(spacing: SUSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, Color.white)
                .symbolEffect(.drawOn, isActive: !drawn)
            Text(String(localized: "Saved"))
                .font(SUFont.screenTitle)
                .foregroundStyle(SUColor.textPrimary)
            SUAmountView(money: total, style: .large)
        }
        .padding(SUSpacing.xxl)
        .background(.regularMaterial, in: SUShape.card)
        .onAppear { drawn = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Expense saved, \(MoneyFormatting.spokenString(total))"))
        .accessibilityIdentifier("compose.saved")
    }
}
