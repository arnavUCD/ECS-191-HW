import Foundation

/// The single place where money becomes text, or text becomes money.
///
/// Views never call `formatted(.currency…)` directly; they go through this type (usually via
/// `SUAmountView`) so precision, sign handling, and accessibility phrasing stay consistent.
nonisolated enum MoneyFormatting {
    /// Formats the magnitude of `money` with the currency's minor-unit precision.
    /// Direction ("you owe", "+", "−") is conveyed separately by the caller.
    static func string(_ money: Money, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = money.currency.minorUnitDigits
        return money.magnitude.amount.formatted(
            .currency(code: money.currency.rawValue)
                .locale(locale)
                .precision(.fractionLength(digits))
        )
    }

    /// Formats with an explicit leading sign glyph for ledgers ("+$12.00", "−$4.50").
    /// Zero renders without a sign.
    static func signedString(_ money: Money, locale: Locale = .autoupdatingCurrent) -> String {
        let base = string(money, locale: locale)
        if money.isPositive { return "+" + base }
        if money.isNegative { return "\u{2212}" + base }
        return base
    }

    /// A compact form for tight layouts ("$1.2K"). Never used where an exact value is required
    /// without the exact value also being available (e.g. via accessibility label).
    static func compactString(_ money: Money, locale: Locale = .autoupdatingCurrent) -> String {
        money.magnitude.amount.formatted(
            .currency(code: money.currency.rawValue)
                .locale(locale)
                .notation(.compactName)
                .precision(.significantDigits(1...3))
        )
    }

    /// Spoken form for VoiceOver, e.g. "42 dollars and 50 cents" in English locales.
    static func spokenString(_ money: Money, locale: Locale = .autoupdatingCurrent) -> String {
        money.magnitude.amount.formatted(
            .currency(code: money.currency.rawValue)
                .locale(locale)
                .presentation(.fullName)
                .precision(.fractionLength(money.currency.minorUnitDigits))
        )
    }

    /// Locale-aware parsing of user-typed text such as "1,234.50" or "$12".
    /// Returns `nil` for anything that is not an unambiguous non-negative amount.
    static func parse(_ text: String, currency: CurrencyCode, locale: Locale = .autoupdatingCurrent) -> Money? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let currencyStyle = Decimal.FormatStyle.Currency(code: currency.rawValue, locale: locale)
        if let value = try? Decimal(trimmed, format: currencyStyle), value >= 0 {
            return Money(value, currency)
        }
        if let value = try? Decimal(trimmed, format: Decimal.FormatStyle(locale: locale)), value >= 0 {
            return Money(value, currency)
        }
        return nil
    }
}
