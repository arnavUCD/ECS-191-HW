import SwiftUI

/// The only component that renders money.
///
/// Direction is expressed with a sign glyph and colour *and* is spoken in the accessibility
/// label; callers add wording ("you lent", "you owe") nearby so colour is never the sole cue.
struct SUAmountView: View {
    enum Style {
        case hero
        case large
        case row
        case small

        var font: Font {
            switch self {
            case .hero: SUFont.heroAmount
            case .large: SUFont.largeAmount
            case .row: SUFont.rowAmount
            case .small: SUFont.smallAmount
            }
        }
    }

    enum Direction: Equatable {
        /// No sign, primary text colour.
        case neutral
        /// Money coming to the user: "+", positive tone.
        case incoming
        /// Money the user owes: "−", negative tone.
        case outgoing
        /// De-emphasised context amount (e.g. a total you were not part of).
        case muted
    }

    let money: Money
    var direction: Direction = .neutral
    var style: Style = .row
    /// Hero figures scale down to fit one line rather than wrapping mid-number.
    var minimumScaleFactor: CGFloat = 0.5
    /// Hero and large figures: the whole units lead and the minor units (and anything after the
    /// decimal separator) sit back in the secondary colour. The spoken amount is unchanged. An
    /// incoming or outgoing amount stays one colour throughout — sign, symbol, and minor units.
    var emphasizesWholeUnits = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    /// Hero numerals are larger than any text style; this keeps them on the Dynamic Type curve.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52

    var body: some View {
        styledText
            .font(style == .hero ? .system(size: heroSize, weight: .medium).monospacedDigit() : style.font)
            .kerning(style == .hero ? -1.4 : 0)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: displayValue))
            .accessibilityLabel(accessibilityText)
    }

    /// With `emphasizesWholeUnits`, everything but the sign and the whole units recedes: the
    /// currency symbol and the minor units ("$" and ".61" in "$884.61"), in any locale's order.
    /// Only for neutral amounts: a green or red amount is read as one figure.
    private var styledText: Text {
        let text = text
        guard emphasizesWholeUnits, direction == .neutral || direction == .muted,
              let firstDigit = text.firstIndex(where: \.isNumber),
              let lastDigit = text.lastIndex(where: \.isNumber) else {
            return Text(text)
        }
        let afterDigits = text.index(after: lastDigit)
        var wholeEnd = afterDigits
        if let separator = locale.decimalSeparator, let range = text.range(of: separator, options: .backwards, range: firstDigit..<afterDigits) {
            wholeEnd = range.lowerBound
        }
        let prefix = String(text[..<firstDigit])
        let sign = String(prefix.filter { $0 == "+" || $0 == "\u{2212}" || $0 == "-" })
        let symbol = String(prefix.filter { $0 != "+" && $0 != "\u{2212}" && $0 != "-" })
        let whole = String(text[firstDigit..<wholeEnd])
        let minor = Text(String(text[wholeEnd...])).foregroundStyle(SUColor.textTertiary)
        let dimmedSymbol = Text(symbol).foregroundStyle(SUColor.textTertiary)
        return Text("\(sign)\(dimmedSymbol)\(whole)\(minor)")
    }

    private var text: String {
        switch direction {
        case .incoming: "+" + MoneyFormatting.string(money, locale: locale)
        case .outgoing: "\u{2212}" + MoneyFormatting.string(money, locale: locale)
        case .neutral, .muted: MoneyFormatting.string(money, locale: locale)
        }
    }

    private var color: Color {
        switch direction {
        case .neutral: SUColor.textPrimary
        case .incoming: SUColor.positive
        case .outgoing: SUColor.negative
        case .muted: SUColor.textTertiary
        }
    }

    /// Display-only value used to choose the numeric roll direction. Not used for math.
    private var displayValue: Double {
        NSDecimalNumber(decimal: money.amount).doubleValue
    }

    private var accessibilityText: String {
        let spoken = MoneyFormatting.spokenString(money, locale: locale)
        switch direction {
        case .incoming: return String(localized: "plus \(spoken)")
        case .outgoing: return String(localized: "minus \(spoken)")
        case .neutral, .muted: return spoken
        }
    }
}

#Preview("Amounts", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: SUSpacing.sm) {
        SUAmountView(money: Money(522.61), style: .hero, emphasizesWholeUnits: true)
        SUAmountView(money: Money(1_234_567.89), style: .hero)
        SUAmountView(money: Money(86.40), direction: .incoming, style: .large)
        SUAmountView(money: Money(29.69), direction: .outgoing, style: .row)
        SUAmountView(money: Money(156), direction: .muted, style: .small)
        SUAmountView(money: Money(1200, .jpy), style: .row)
        SUAmountView(money: Money(12.5, .eur), style: .row).environment(\.locale, Locale(identifier: "de_DE"))
    }
    .padding()
    .background(SUColor.backgroundPrimary)
}
