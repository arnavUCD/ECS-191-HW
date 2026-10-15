import SwiftUI

/// Attention as icon + words + tone, never colour alone (milestone 3 §6.5).
struct ReceiptAttentionChip: View {
    let attention: ReceiptAttention
    var compact = false

    var body: some View {
        SUCapsuleLabel(title: ReceiptLanguage.label(attention), systemImage: ReceiptLanguage.symbol(attention), tone: tone,
                       prominence: compact ? .outlined : .tinted)
    }

    private var tone: SUTone {
        switch attention {
        case .looksGood: .positive
        case .check: .warning
        case .needsResolution: .negative
        }
    }
}

/// A money text field that commits only exact values (no rounding of what was typed).
struct ReceiptMoneyField: View {
    let title: String
    let value: Money?
    let currency: CurrencyCode
    var allowsNegative = false
    var allowsEmpty = false
    var identifier: String?
    let commit: (Money?) -> Void

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SUSpacing.xs) {
                Text(title).font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                Spacer(minLength: SUSpacing.xs)
                TextField(title, text: $text, prompt: Text(verbatim: currency.minorUnitDigits == 0 ? "0" : "0.00"))
                    .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(SUFont.rowAmount)
                    .frame(minWidth: 90, maxWidth: 160, minHeight: SUMetrics.minimumTouchTarget)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(apply)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier ?? "")
            }
            if isInvalid {
                Label(allowsNegative ? String(localized: "Enter an amount like 12.50 or -2.00.") : String(localized: "Enter an amount like 12.50."),
                      systemImage: "exclamationmark.circle")
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.negative)
            }
        }
        .onAppear { text = ReceiptAmountInput.text(value, locale: locale) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = ReceiptAmountInput.text(newValue, locale: locale) }
        }
        .onChange(of: isFocused) { _, focused in if !focused { apply() } }
        .onChange(of: text) { _, _ in
            if let parsed = ReceiptAmountInput.parse(text, currency: currency, allowsNegative: allowsNegative, locale: locale), parsed != value {
                isInvalid = false
                commit(parsed)
            }
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, allowsEmpty {
            isInvalid = false
            if value != nil { commit(nil) }
            return
        }
        if let parsed = ReceiptAmountInput.parse(trimmed, currency: currency, allowsNegative: allowsNegative, locale: locale) {
            isInvalid = false
            if parsed != value { commit(parsed) }
            text = ReceiptAmountInput.text(parsed, locale: locale)
        } else {
            isInvalid = true
        }
    }
}

/// One editable line in review: name, quantity × price, amount, and attention.
struct ReceiptLineRow: View {
    let title: String
    let detail: String?
    let amount: Money
    let attention: ReceiptAttention
    let reason: String?
    var isSelected = false
    var badge: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SUSpacing.xs) {
                    Text(title.isEmpty ? String(localized: "Unnamed item") : title)
                        .font(SUFont.body.weight(.medium))
                        .foregroundStyle(title.isEmpty ? SUColor.textTertiary : SUColor.textPrimary)
                        .lineLimit(3)
                    if let badge { SUCapsuleLabel(title: badge, systemImage: "arrow.uturn.backward", tone: .informational, prominence: .outlined) }
                }
                if let detail {
                    Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                if attention != .looksGood {
                    ReceiptAttentionChip(attention: attention, compact: true)
                }
            }
            Spacer(minLength: SUSpacing.xs)
            ReceiptAmountText(money: amount)
                .accessibilityHidden(true)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SUSpacing.xs)
        .padding(.horizontal, SUSpacing.xs)
        .background(isSelected ? SUColor.accent.opacity(0.12) : .clear, in: SUShape.control)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? String(localized: "Unnamed item") : title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(String(localized: "Opens the editor and shows where this was read on the receipt."))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: String {
        var parts = [MoneyFormatting.spokenString(amount) + (amount.isNegative ? String(localized: ", credit") : "")]
        if let detail { parts.append(detail) }
        if attention != .looksGood { parts.append(ReceiptLanguage.label(attention)) }
        if let reason, attention != .looksGood { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

/// A receipt amount with an explicit sign: credits (discounts, refunds) read "−$4.00", never "+".
struct ReceiptAmountText: View {
    let money: Money
    var font: Font = SUFont.rowAmount
    @Environment(\.locale) private var locale

    var body: some View {
        Text(money.isNegative ? "\u{2212}" + MoneyFormatting.string(money, locale: locale) : MoneyFormatting.string(money, locale: locale))
            .font(font)
            .foregroundStyle(money.isNegative ? SUColor.positive : SUColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(money.isNegative
                ? String(localized: "credit \(MoneyFormatting.spokenString(money, locale: locale))")
                : MoneyFormatting.spokenString(money, locale: locale))
    }
}
