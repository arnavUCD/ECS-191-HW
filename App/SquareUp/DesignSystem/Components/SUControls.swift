import SwiftUI

/// Section title with an optional trailing action ("See all").
struct SUSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SUFont.sectionTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            Spacer(minLength: SUSpacing.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.suPill)
            }
        }
    }
}

/// A full-name, avatar-first selectable row for choosing people.
struct SUUserPickerRow: View {
    let member: Member
    var detail: String?
    var isCurrentUser = false
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SUSpacing.sm) {
                SUAvatar(member: member, size: .medium, isCurrentUser: isCurrentUser)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SUSpacing.xs) {
                        Text(member.displayName)
                            .font(SUFont.body.weight(.semibold))
                            .foregroundStyle(SUColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        if isCurrentUser { SURoleBadge(kind: .you) }
                    }
                    if let detail {
                        Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? SUColor.accent : SUColor.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCurrentUser ? String(localized: "\(member.displayName), you") : member.displayName)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension SplitMethod {
    var label: String {
        switch self {
        case .equal: String(localized: "Equally")
        case .exact: String(localized: "Exact amounts")
        case .percentage: String(localized: "Percentages")
        case .shares: String(localized: "Shares")
        case .itemized: String(localized: "By item")
        }
    }

    var shortLabel: String {
        switch self {
        case .equal: String(localized: "Equal")
        case .exact: String(localized: "Exact")
        case .percentage: String(localized: "Percent")
        case .shares: String(localized: "Shares")
        case .itemized: String(localized: "Items")
        }
    }

    var symbolName: String {
        switch self {
        case .equal: "equal.circle"
        case .exact: "dollarsign.circle"
        case .percentage: "percent"
        case .shares: "chart.pie"
        case .itemized: "list.bullet.rectangle"
        }
    }
}

/// Capsule picker for split methods, on a Liquid Glass track. VoiceOver and Voice Control see
/// a standard picker via `accessibilityRepresentation`.
struct SUSplitMethodPicker: View {
    @Binding var selection: SplitMethod
    var methods: [SplitMethod] = SplitMethod.manualMethods

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SUSpacing.xxs) { options }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SUSpacing.xxs) { options }
                }
            }
            .padding(SUSpacing.xxs)
            .glassEffect(.regular, in: Capsule())
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker(String(localized: "Split method"), selection: $selection) {
                ForEach(methods, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }

    private var options: some View {
        ForEach(methods, id: \.self) { method in
            Button {
                withSUAnimation(.reconcile, reduceMotion: reduceMotion) { selection = method }
            } label: {
                Label(method.shortLabel, systemImage: method.symbolName)
                    .font(SUFont.chip)
                    .lineLimit(1)
                    .padding(.horizontal, SUSpacing.sm)
                    .frame(minHeight: SUMetrics.minimumTouchTarget - 4)
                    .foregroundStyle(selection == method ? Color.black : SUColor.textPrimary)
                    .background {
                        if selection == method {
                            Capsule().fill(.white).matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Inline confirmation or notice. Tone is paired with a symbol and words.
struct SUConfirmationBanner: View {
    let title: String
    var message: String?
    var systemImage: String
    var tone: SUTone
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: SUSpacing.sm) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SUFont.supporting.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                if let message {
                    Text(message).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(SUFont.supporting.weight(.semibold))
                    .frame(minHeight: SUMetrics.minimumTouchTarget)
            }
        }
        .padding(SUSpacing.sm + 2)
        .background(tone.color.opacity(0.12), in: SUShape.compact)
        .overlay { SUShape.compact.strokeBorder(tone.color.opacity(0.2), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// A bottom action bar on Liquid Glass for a sheet's primary action.
struct SUFloatingActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: SUSpacing.sm) { content }
                .padding(SUSpacing.xs)
        }
        .padding(.horizontal, SUSpacing.md)
        .padding(.bottom, SUSpacing.xs)
    }
}

#Preview("Controls") {
    @Previewable @State var method = SplitMethod.equal
    let snapshot = SampleLedger.make(referenceDate: .now)
    let members = snapshot.members.values.sorted { $0.displayName < $1.displayName }
    ScrollView {
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            SUSectionHeader(title: "Recent activity", actionTitle: "See all") {}
            SUSplitMethodPicker(selection: $method)
            GlassEffectContainer {
                HStack(spacing: SUSpacing.xs) {
                    SUActionTile(title: "Add expense", systemImage: "plus", isProminent: true) {}
                    SUActionTile(title: "Scan receipt", systemImage: "doc.viewfinder") {}
                    SUActionTile(title: "Settle up", systemImage: "checkmark") {}
                }
            }
            SUUserPickerRow(member: members[0], detail: "@riley", isCurrentUser: true, isSelected: true) {}
            SUUserPickerRow(member: members[5], detail: "@lena", isSelected: false) {}
            SUConfirmationBanner(
                title: "You're offline", message: "Changes are saved on this iPhone.",
                systemImage: "icloud.slash", tone: .warning
            )
            SUConfirmationBanner(title: "Expense saved", systemImage: "checkmark.circle.fill", tone: .positive)
        }
        .padding()
    }
    .suScreenBackground()
    .squareUpTheme()
}
