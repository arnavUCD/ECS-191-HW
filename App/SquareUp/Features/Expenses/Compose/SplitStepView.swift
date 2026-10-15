import SwiftUI

/// Step 2: payer, participants, and split method with a live reconciliation summary.
struct SplitStepView: View {
    @Bindable var model: ComposeExpenseModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.xl) {
                payerSection
                VStack(alignment: .leading, spacing: SUSpacing.sm) {
                    SUSectionHeader(title: String(localized: "How to split"))
                    SUSplitMethodPicker(selection: $model.method)
                }
                participantsSection
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.md)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            ReconciliationBar(model: model) {
                withSUAnimation(.reveal, reduceMotion: reduceMotion) { model.advance() }
            }
        }
    }

    private var payerSection: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            HStack {
                SUSectionHeader(title: String(localized: "Paid by"))
                if model.suggestedFields.contains(.payer) { SuggestedBadge() }
            }
            Toggle(String(localized: "More than one person paid"), isOn: Binding(
                get: { model.isMultiplePayers },
                set: { enabled in withSUAnimation(.reconcile, reduceMotion: reduceMotion) { model.setMultiplePayers(enabled) } }
            ))
            .tint(SUColor.accent)
            .accessibilityIdentifier("compose.multiplePayers")
            if model.isMultiplePayers {
                multiplePayers
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: SUSpacing.md) {
                        ForEach(model.members) { member in
                            let isPayer = model.payerID == member.id
                            Button {
                                withSUAnimation(.reconcile, reduceMotion: reduceMotion) { model.setPayer(member.id) }
                            } label: {
                                VStack(spacing: SUSpacing.xs) {
                                    SUAvatar(member: member, size: .large, isCurrentUser: member.id == model.currentUserID, isSelected: isPayer)
                                    Text(member.id == model.currentUserID ? String(localized: "You") : member.displayName)
                                        .font(SUFont.metadata.weight(isPayer ? .semibold : .regular))
                                        .foregroundStyle(isPayer ? SUColor.textPrimary : SUColor.textSecondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 76)
                                }
                            }
                            .buttonStyle(.suPressable)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(member.id == model.currentUserID ? String(localized: "\(member.displayName), you") : member.displayName)
                            .accessibilityAddTraits(isPayer ? [.isButton, .isSelected] : .isButton)
                            .accessibilityIdentifier("compose.payer.\(member.firstName)")
                        }
                    }
                    .padding(.vertical, SUSpacing.xxs)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.payerID)
    }

    /// Explicit contributions that must add up to the total.
    private var multiplePayers: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            SUCard(padding: SUSpacing.sm) {
                VStack(spacing: 0) {
                    ForEach(model.members) { member in
                        HStack(spacing: SUSpacing.sm) {
                            SUAvatar(member: member, size: .small, isCurrentUser: member.id == model.currentUserID)
                            Text(member.id == model.currentUserID ? String(localized: "\(member.displayName) (you)") : member.displayName)
                                .font(SUFont.body)
                            Spacer(minLength: SUSpacing.xs)
                            HStack(spacing: SUSpacing.xxs) {
                                Text(CurrencyAffixes(currency: model.currency, locale: locale).prefix).foregroundStyle(SUColor.textSecondary)
                                TextField("0", text: Binding(
                                    get: { model.payerAmountText[member.id] ?? "" },
                                    set: { model.payerAmountText[member.id] = $0 }
                                ))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(SUFont.rowAmount)
                                .frame(width: 96)
                                .accessibilityLabel(String(localized: "Amount \(member.displayName) paid"))
                                .accessibilityIdentifier("compose.paid.\(member.firstName)")
                            }
                            .padding(.horizontal, SUSpacing.sm)
                            .frame(minHeight: SUMetrics.minimumTouchTarget)
                            .suSurface(SUShape.control, elevated: true)
                        }
                        .frame(minHeight: 52)
                        if member.id != model.members.last?.id { Divider().padding(.leading, 40) }
                    }
                }
            }
            Label(payerStatus, systemImage: model.payerReconciliation.isBalanced ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(SUFont.metadata)
                .foregroundStyle(model.payerReconciliation.isBalanced ? SUColor.positive : SUColor.warning)
                .accessibilityIdentifier("compose.payerStatus")
        }
    }

    private var payerStatus: String {
        let format = { (money: Money) in MoneyFormatting.string(money, locale: locale) }
        switch model.payerReconciliation.state {
        case .balanced: return String(localized: "Payments add up to the total")
        case .remaining(let money): return String(localized: "\(format(money)) of the total isn't paid by anyone yet")
        case .over(let money): return String(localized: "Payments are \(format(money)) more than the total")
        case .incomplete(.unreadableValue): return String(localized: "One of the amounts can't be read")
        default: return String(localized: "Enter what each person paid")
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            HStack {
                SUSectionHeader(title: String(localized: "Split between"))
                if model.suggestedFields.contains(.participants) { SuggestedBadge() }
                Spacer()
                let all = model.participantIDs.count == model.members.count
                Button(all ? String(localized: "Clear") : String(localized: "Everyone")) {
                    model.setAllParticipants(!all)
                }
                .font(SUFont.supporting.weight(.semibold))
                .frame(minHeight: SUMetrics.minimumTouchTarget)
            }
            SUCard(padding: SUSpacing.sm) {
                VStack(spacing: 0) {
                    ForEach(model.members) { member in
                        ParticipantRow(model: model, member: member)
                        if member.id != model.members.last?.id { Divider().padding(.leading, 52) }
                    }
                }
            }
            if model.method == .exact, case .remaining = model.reconciliation.state {
                Button(String(localized: "Split the rest equally"), systemImage: "equal.circle") {
                    withSUAnimation(.reconcile, reduceMotion: reduceMotion) { model.distributeRemainingExact() }
                }
                .buttonStyle(.suSecondary)
            }
        }
    }
}

private struct ParticipantRow: View {
    @Bindable var model: ComposeExpenseModel
    let member: Member
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    var body: some View {
        let selected = model.isParticipant(member.id)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.xs))
            : AnyLayout(HStackLayout(spacing: SUSpacing.sm))
        layout {
            Button {
                model.toggleParticipant(member.id)
            } label: {
                HStack(spacing: SUSpacing.sm) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? SUColor.accent : SUColor.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                    SUAvatar(member: member, size: .small, isCurrentUser: member.id == model.currentUserID)
                    Text(member.id == model.currentUserID ? String(localized: "\(member.displayName) (you)") : member.displayName)
                        .font(SUFont.body)
                        .foregroundStyle(SUColor.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(member.displayName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("compose.participant.\(member.firstName)")

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: SUSpacing.xs) }

            if selected { input }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    @ViewBuilder
    private var input: some View {
        switch model.method {
        case .equal, .itemized:
            if let share = model.computedShare(for: member.id) {
                SUAmountView(money: share, style: .row)
            }
        case .exact:
            HStack(spacing: SUSpacing.xxs) {
                Text(CurrencyAffixes(currency: model.currency, locale: locale).prefix)
                    .foregroundStyle(SUColor.textSecondary)
                TextField("0", text: binding(\.exactText))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(SUFont.rowAmount)
                    .frame(width: 96)
                    .accessibilityLabel(String(localized: "Amount for \(member.displayName)"))
            }
            .padding(.horizontal, SUSpacing.sm)
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .suSurface(SUShape.control, elevated: true)
        case .percentage:
            HStack(spacing: SUSpacing.xxs) {
                TextField("0", text: binding(\.percentText))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(SUFont.rowAmount)
                    .frame(width: 64)
                    .accessibilityLabel(String(localized: "Percent for \(member.displayName)"))
                Text("%").foregroundStyle(SUColor.textSecondary)
            }
            .padding(.horizontal, SUSpacing.sm)
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .suSurface(SUShape.control, elevated: true)
        case .shares:
            Stepper(value: Binding(
                get: { model.shareWeight(for: member.id) },
                set: { model.shareWeights[member.id] = $0 }
            ), in: 0...99) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(localized: "\(model.shareWeight(for: member.id)) shares"))
                        .font(SUFont.supporting.monospacedDigit())
                        .foregroundStyle(SUColor.textPrimary)
                    if let share = model.computedShare(for: member.id) {
                        SUAmountView(money: share, direction: .muted, style: .small)
                    }
                }
            }
            .fixedSize()
            .accessibilityLabel(String(localized: "Shares for \(member.displayName)"))
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<ComposeExpenseModel, [MemberID: String]>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath][member.id] ?? "" },
            set: { model[keyPath: keyPath][member.id] = $0 }
        )
    }
}

/// Live reconciliation: what's left to assign, or confirmation that it adds up.
private struct ReconciliationBar: View {
    let model: ComposeExpenseModel
    let next: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: SUSpacing.xs) {
            HStack(spacing: SUSpacing.xs) {
                Image(systemName: model.reconciliation.isBalanced ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.reconciliation.isBalanced ? SUColor.positive : SUColor.warning)
                    .contentTransition(.symbolEffect(.replace))
                Text(statusText)
                    .font(SUFont.supporting.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .contentTransition(.numericText())
                Spacer()
                SUAmountView(money: model.total, direction: .muted, style: .small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("compose.reconciliation")

            Button(String(localized: "Review"), action: next)
                .buttonStyle(.suPrimary)
                .disabled(!model.canContinueFromSplit)
                .accessibilityIdentifier("compose.review")
        }
        .padding(SUSpacing.md)
        .glassEffect(.regular, in: SUShape.card)
        .padding(.horizontal, SUSpacing.sm)
        .padding(.bottom, SUSpacing.xxs)
        .frame(maxWidth: 560)
        .suAnimation(.reconcile, value: model.reconciliation)
    }

    private var statusText: String {
        let format = { (money: Money) in MoneyFormatting.string(money, locale: locale) }
        switch model.reconciliation.state {
        case .balanced:
            return String(localized: "Adds up to the total")
        case .remaining(let money):
            return String(localized: "\(format(money)) left to assign")
        case .over(let money):
            return String(localized: "\(format(money)) over the total")
        case .percentRemaining(let value):
            return String(localized: "\(value.formatted(.number.locale(locale)))% left to assign")
        case .percentOver(let value):
            return String(localized: "\(value.formatted(.number.locale(locale)))% over 100%")
        case .incomplete(.noParticipants):
            return String(localized: "Choose who shares this")
        case .incomplete(.noAmount):
            return String(localized: "Enter an amount first")
        case .incomplete(.zeroShares):
            return String(localized: "Give at least one person a share")
        case .incomplete(.unreadableValue):
            return String(localized: "One of the values can't be read")
        }
    }
}
