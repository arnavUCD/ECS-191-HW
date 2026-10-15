import SwiftUI

/// A ledger row: what happened, who paid, and what it means for the current user.
///
/// Hierarchy: the effect amount leads on the trailing edge; the title and payer explain it;
/// group and date are metadata. At accessibility text sizes the row stacks vertically.
struct SUTransactionRow: View {
    let entry: ActivityEntry
    let members: [MemberID: Member]
    var showsGroup = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    HStack(spacing: SUSpacing.sm) {
                        icon
                        titleBlock
                    }
                    effectBlock(alignment: .leading)
                }
            } else {
                HStack(spacing: SUSpacing.sm) {
                    icon
                    titleBlock
                    Spacer(minLength: SUSpacing.xs)
                    effectBlock(alignment: .trailing)
                }
            }
        }
        .padding(.vertical, SUSpacing.xs)
        .frame(minHeight: SUMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var icon: some View {
        let symbol: String
        let tint: Color
        switch entry.kind {
        case .expense:
            symbol = entry.category?.symbolName ?? "receipt"
            tint = entry.category?.color ?? SUColor.textSecondary
        case .settlement:
            symbol = "arrow.left.arrow.right"
            tint = SUColor.informational
        case .event:
            symbol = entry.eventDescription?.symbolName ?? "clock"
            tint = Self.color(for: entry.eventDescription?.tone ?? .neutral)
        }
        return Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.14), in: SUShape.control)
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(SUFont.cardTitle)
                .foregroundStyle(SUColor.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(subtitle)
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
    }

    private func effectBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if !effectLabel.isEmpty {
                Text(effectLabel)
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
            }
            if let amount = effectAmount {
                SUAmountView(money: amount.money, direction: amount.direction, style: .row)
            }
        }
    }

    /// Short names disambiguated across everyone shown (two Alexes become "Alex M." / "Alex R.").
    private var labels: [MemberID: String] { PersonIdentity.shortLabels(for: Array(members.values)) }

    private var payerName: String {
        labels[entry.actorID] ?? String(localized: "Someone")
    }

    private var subtitle: String {
        let date = entry.date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        switch entry.kind {
        case .expense:
            let base = String(localized: "\(payerName) paid \(MoneyFormatting.string(entry.total, locale: locale))")
            return showsGroup ? "\(base) · \(entry.groupName)" : "\(base) · \(date)"
        case .settlement:
            var recorded = String(localized: "Recorded payment")
            if let provider = entry.provider {
                recorded = entry.confirmedBy.map { String(localized: "\(provider.displayName) · confirmed by \(labels[$0] ?? "")") }
                    ?? provider.displayName
            }
            return showsGroup ? "\(recorded) · \(entry.groupName)" : "\(recorded) · \(date)"
        case .event:
            let detail = entry.eventDescription?.detail
            let context = showsGroup ? entry.groupName : date
            return detail.map { "\($0) · \(context)" } ?? context
        }
    }

    static func color(for tone: AuditEventDescription.Tone) -> Color {
        switch tone {
        case .neutral: SUColor.textSecondary
        case .positive: SUColor.positive
        case .warning: SUColor.warning
        case .negative: SUColor.negative
        case .informational: SUColor.informational
        }
    }

    private var effectLabel: String {
        switch entry.effect {
        case .lent: String(localized: "you lent")
        case .borrowed: String(localized: "you borrowed")
        case .even: String(localized: "your share is paid")
        case .paidBack: String(localized: "you paid back")
        case .receivedPayment: String(localized: "you received")
        case .notInvolved: String(localized: "not involved")
        case .event: ""
        }
    }

    private var effectAmount: (money: Money, direction: SUAmountView.Direction)? {
        switch entry.effect {
        case .lent(let money): (money, .incoming)
        case .borrowed(let money): (money, .outgoing)
        case .paidBack(_, let money): (money, .neutral)
        case .receivedPayment(_, let money): (money, .incoming)
        case .even, .notInvolved: nil
        case .event: entry.eventDescription?.amount.map { ($0, SUAmountView.Direction.muted) }
        }
    }

    private var accessibilitySummary: String {
        var parts = [entry.title, subtitle, effectLabel].filter { !$0.isEmpty }
        if let amount = effectAmount {
            parts.append(MoneyFormatting.spokenString(amount.money, locale: locale))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Transaction rows") {
    let snapshot = SampleLedger.make(referenceDate: .now)
    let entries = ActivityFeedBuilder.entries(from: snapshot)
    List(entries) { entry in
        SUTransactionRow(entry: entry, members: snapshot.members)
    }
    .listStyle(.plain)
}
