import SwiftUI

/// Large-target numeric keypad for amount entry (inspired by the calculator-style references).
///
/// Every key is a labelled button, so VoiceOver, Voice Control, Switch Control, and Full
/// Keyboard Access work. Hardware keyboards are handled by the owning screen via `onKeyPress`.
struct SUKeypad: View {
    var allowsDecimal = true
    let onKey: (AmountEntry.Key) -> Void

    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .title) private var keyHeight: CGFloat = 56

    private let rows: [[AmountEntry.Key]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.decimalSeparator, .digit(0), .delete],
    ]

    var body: some View {
        Grid(horizontalSpacing: SUSpacing.xs, verticalSpacing: SUSpacing.xs) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        key(rows[row][column])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func key(_ key: AmountEntry.Key) -> some View {
        let isDisabled = key == .decimalSeparator && !allowsDecimal
        Button {
            onKey(key)
        } label: {
            label(for: key)
                .font(.system(.title, design: .rounded, weight: .medium))
                .foregroundStyle(isDisabled ? SUColor.textTertiary.opacity(0.4) : SUColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: max(keyHeight, SUMetrics.minimumTouchTarget))
                .background(SUColor.glassFillElevated.opacity(key == .delete || key == .decimalSeparator ? 0 : 1), in: SUShape.control)
                .overlay {
                    if key != .delete, key != .decimalSeparator {
                        SUShape.control.strokeBorder(SUColor.hairline, lineWidth: 1)
                    }
                }
                .contentShape(SUShape.control)
        }
        .buttonStyle(.suPressable)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel(for: key))
        .buttonRepeatBehavior(key == .delete ? .enabled : .disabled)
    }

    @ViewBuilder
    private func label(for key: AmountEntry.Key) -> some View {
        switch key {
        case .digit(let value): Text(value.formatted(.number.locale(locale)))
        case .decimalSeparator: Text(locale.decimalSeparator ?? ".")
        case .delete: Image(systemName: "delete.left")
        case .clear: Image(systemName: "xmark")
        }
    }

    private func accessibilityLabel(for key: AmountEntry.Key) -> String {
        switch key {
        case .digit(let value): value.formatted(.number.locale(locale))
        case .decimalSeparator: String(localized: "Decimal point")
        case .delete: String(localized: "Delete")
        case .clear: String(localized: "Clear")
        }
    }
}

#Preview("Keypad") {
    @Previewable @State var entry = AmountEntry()
    VStack(spacing: SUSpacing.xl) {
        Text(entry.displayText())
            .font(SUFont.heroAmount)
            .contentTransition(.numericText())
        SUKeypad { key in
            withAnimation(.snappy) { _ = entry.apply(key) }
        }
    }
    .padding()
    .background(SUColor.backgroundPrimary)
}
