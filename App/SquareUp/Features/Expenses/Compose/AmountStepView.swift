import SwiftUI
import TipKit

/// Step 1: group, amount, and what it was for — all immediately accessible.
struct AmountStepView: View {
    @Bindable var model: ComposeExpenseModel
    let openQuickEntry: () -> Void

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isKeypadFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var shake = 0
    @Environment(AppRouter.self) private var router

    private let quickEntryTip = QuickEntryTip()

    var body: some View {
        ScrollView {
            VStack(spacing: SUSpacing.lg) {
                groupPicker

                if let suggestion = model.suggestion {
                    SuggestionBanner(suggestion: suggestion) { model.dismissSuggestion() }
                }

                amountDisplay

                VStack(spacing: SUSpacing.sm) {
                    titleField
                    HStack {
                        categoryMenu
                        Spacer()
                        if !model.isEditing {
                            Button(String(localized: "Scan"), systemImage: "doc.viewfinder") {
                                router.switchFromComposerToReceipt(groupID: model.groupID)
                            }
                            .font(SUFont.supporting.weight(.semibold))
                            .frame(minHeight: SUMetrics.minimumTouchTarget)
                            .accessibilityLabel(String(localized: "Scan a receipt instead"))
                            .accessibilityIdentifier("compose.scanReceipt")
                        }
                        Button(String(localized: "Describe it"), systemImage: "text.bubble", action: openQuickEntry)
                            .font(SUFont.supporting.weight(.semibold))
                            .frame(minHeight: SUMetrics.minimumTouchTarget)
                            .popoverTip(quickEntryTip, arrowEdge: .bottom)
                            .accessibilityIdentifier("compose.quickEntry")
                    }
                }

                SUKeypad(allowsDecimal: model.currency.minorUnitDigits > 0) { key in
                    withSUAnimation(.press, reduceMotion: reduceMotion) { model.press(key) }
                }
                .focusable()
                .focused($isKeypadFocused)
                .onKeyPress(phases: .down, action: handleHardwareKey)
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: SUSpacing.xs) {
                if let issue = model.amountStepIssue, !model.entry.isEmpty || !model.title.isEmpty {
                    Text(issue)
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textSecondary)
                        .accessibilityIdentifier("compose.amountIssue")
                }
                Button(String(localized: "Next")) {
                    withSUAnimation(.reveal, reduceMotion: reduceMotion) { model.advance() }
                }
                .buttonStyle(.suPrimary)
                .disabled(model.amountStepIssue != nil)
                .accessibilityIdentifier("compose.next")
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.xs)
            .frame(maxWidth: 520)
        }
        .onChange(of: model.rejectionCount) { shake += 1 }
        .onAppear { isKeypadFocused = true }
    }

    private var groupPicker: some View {
        Menu {
            Picker(String(localized: "Group"), selection: Binding(
                get: { model.groupID },
                set: { if let id = $0 { model.selectGroup(id) } }
            )) {
                ForEach(model.groups) { group in
                    Label(group.name, systemImage: group.symbolName).tag(Optional(group.id))
                }
            }
        } label: {
            HStack(spacing: SUSpacing.xs) {
                if let group = model.group { SUGroupMark(group: group, size: 28) }
                Text(model.group?.name ?? String(localized: "Choose a group"))
                    .font(SUFont.supporting.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SUColor.textSecondary)
            }
            .padding(.horizontal, SUSpacing.sm)
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .disabled(model.isEditing)
        .accessibilityLabel(String(localized: "Group: \(model.group?.name ?? "")"))
        .accessibilityIdentifier("compose.group")
        .padding(.top, SUSpacing.sm)
    }

    private var amountDisplay: some View {
        let allowsShake = !reduceMotion
        return VStack(spacing: SUSpacing.xxs) {
            Text(model.entry.displayText(locale: locale))
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(model.entry.isEmpty ? SUColor.textTertiary : SUColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: NSDecimalNumber(decimal: model.total.amount).doubleValue))
                .keyframeAnimator(initialValue: CGFloat.zero, trigger: shake) { content, offset in
                    content.offset(x: allowsShake ? offset : 0)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(-10, duration: 0.07)
                        SpringKeyframe(8, duration: 0.07)
                        SpringKeyframe(-4, duration: 0.07)
                        SpringKeyframe(0, duration: 0.1)
                    }
                }
                .accessibilityLabel(String(localized: "Amount"))
                .accessibilityValue(MoneyFormatting.spokenString(model.total, locale: locale))
                .accessibilityIdentifier("compose.amount")
            if model.suggestedFields.contains(.amount) {
                SuggestedBadge()
            }
            if let rejection = model.lastRejection {
                Text(rejectionText(rejection))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.warning)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SUSpacing.md)
    }

    private var titleField: some View {
        HStack(spacing: SUSpacing.sm) {
            Image(systemName: model.category.symbolName)
                .foregroundStyle(model.category.color)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            TextField(String(localized: "What was it for?"), text: $model.title)
                .font(SUFont.body)
                .submitLabel(.done)
                .focused($isTitleFocused)
                .onSubmit { isKeypadFocused = true }
                .accessibilityIdentifier("compose.title")
            if model.suggestedFields.contains(.title) { SuggestedBadge() }
        }
        .padding(.horizontal, SUSpacing.md)
        .frame(minHeight: 52)
        .suSurface(SUShape.compact)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(ExpenseCategory.allCases, id: \.self) { category in
                Button(category.label, systemImage: category.symbolName) { model.chooseCategory(category) }
            }
        } label: {
            SUCapsuleLabel(title: model.category.label, systemImage: model.category.symbolName, tone: .neutral)
                .frame(minHeight: SUMetrics.minimumTouchTarget)
        }
        .accessibilityLabel(String(localized: "Category: \(model.category.label)"))
        .accessibilityHint(model.isCategoryExplicit ? "" : String(localized: "Suggested from the description"))
    }

    private func handleHardwareKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .delete {
            model.press(.delete)
            return .handled
        }
        guard let character = press.characters.first else { return .ignored }
        if let digit = character.wholeNumberValue {
            model.press(.digit(digit))
            return .handled
        }
        if String(character) == (locale.decimalSeparator ?? ".") || character == "." {
            model.press(.decimalSeparator)
            return .handled
        }
        return .ignored
    }

    private func rejectionText(_ rejection: AmountEntry.Rejection) -> String {
        switch rejection {
        case .tooManyFractionDigits:
            String(localized: "\(model.currency.rawValue) uses \(model.currency.minorUnitDigits) decimal places")
        case .exceedsMaximum:
            String(localized: "That's larger than a single expense can be")
        case .separatorNotAllowed:
            String(localized: "Already has a decimal point")
        case .nothingToDelete, .invalidDigit:
            ""
        }
    }
}

/// Marks a field filled by a suggestion until the person edits it.
struct SuggestedBadge: View {
    var body: some View {
        SUCapsuleLabel(title: String(localized: "Suggested"), systemImage: "sparkles", tone: .insight)
            .accessibilityLabel(String(localized: "Suggested, please review"))
    }
}

/// Explains where a suggestion came from and what still needs review.
struct SuggestionBanner: View {
    let suggestion: QuickEntrySuggestion
    let dismiss: () -> Void

    var body: some View {
        SUConfirmationBanner(
            title: String(localized: "Draft from your description — review each field"),
            message: ([suggestion.provider.location.disclosure] + suggestion.warnings.compactMap(Self.text)).joined(separator: "\n"),
            systemImage: "sparkles",
            tone: .insight,
            actionTitle: String(localized: "Dismiss"),
            action: dismiss
        )
    }

    static func text(_ warning: QuickEntrySuggestion.Warning) -> String? {
        switch warning {
        case .amountMissing: String(localized: "No amount found — enter it below.")
        case .amountInvalid(let text): String(localized: "Couldn't read the amount “\(text)”.")
        case .amountPrecision: String(localized: "The amount was rounded to whole cents.")
        case .unknownPerson(let name): String(localized: "“\(name)” isn't in this group.")
        case .ambiguousPerson(let name): String(localized: "More than one person matches “\(name)” — choose on the next step.")
        case .payerNotFound(let name): String(localized: "Couldn't find payer “\(name)” — choose on the next step.")
        case .nonEqualSplitRequested: String(localized: "Uneven splits aren't filled in automatically — set amounts on the next step.")
        }
    }
}
