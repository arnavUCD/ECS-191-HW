import Foundation

/// The deterministic state machine behind the amount keypad.
///
/// It stores exactly what the person typed (digits and an optional decimal separator) rather
/// than a number, so "12." and "12.50" display faithfully while `money` is always exact.
nonisolated struct AmountEntry: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case digit(Int)
        case decimalSeparator
        case delete
        case clear
    }

    enum Rejection: Equatable, Sendable {
        case tooManyFractionDigits
        case exceedsMaximum
        case separatorNotAllowed
        case nothingToDelete
        case invalidDigit
    }

    let currency: CurrencyCode
    /// Upper bound for a single expense. Prevents accidental extra digits from producing
    /// absurd balances; large-but-real amounts (e.g. rent, venue deposits) fit comfortably.
    let maximum: Money

    private(set) var integerDigits: String = ""
    private(set) var fractionDigits: String?

    init(currency: CurrencyCode = .usd, maximum: Money? = nil) {
        self.currency = currency
        self.maximum = maximum ?? Money(Decimal(10_000_000), currency)
    }

    init(money: Money, maximum: Money? = nil) {
        self.init(currency: money.currency, maximum: maximum)
        guard !money.isZero else { return }
        let digits = money.currency.minorUnitDigits
        let minor = money.magnitude.minorUnits
        var divisor: Int64 = 1
        for _ in 0..<digits { divisor *= 10 }
        integerDigits = String(minor / divisor)
        if digits > 0 {
            let fraction = minor % divisor
            if fraction != 0 {
                var text = String(fraction)
                while text.count < digits { text = "0" + text }
                while text.hasSuffix("0") { text.removeLast() }
                fractionDigits = text
            }
        }
    }

    var isEmpty: Bool { integerDigits.isEmpty && fractionDigits == nil }

    var money: Money {
        let integer = integerDigits.isEmpty ? "0" : integerDigits
        let fraction = fractionDigits.flatMap { $0.isEmpty ? nil : $0 }
        let text = fraction.map { "\(integer).\($0)" } ?? integer
        return Money(string: text, currency: currency) ?? .zero(currency)
    }

    /// Applies a key press. Returns the rejection reason when the key was ignored so the UI
    /// can play a warning haptic and announce why.
    @discardableResult
    mutating func apply(_ key: Key) -> Rejection? {
        switch key {
        case .digit(let value):
            guard (0...9).contains(value) else { return .invalidDigit }
            var candidate = self
            if let fraction = fractionDigits {
                guard fraction.count < currency.minorUnitDigits else { return .tooManyFractionDigits }
                candidate.fractionDigits = fraction + String(value)
            } else if integerDigits == "0" {
                candidate.integerDigits = String(value)
            } else {
                candidate.integerDigits += String(value)
            }
            guard candidate.money <= maximum else { return .exceedsMaximum }
            self = candidate
            return nil

        case .decimalSeparator:
            guard currency.minorUnitDigits > 0, fractionDigits == nil else { return .separatorNotAllowed }
            if integerDigits.isEmpty { integerDigits = "0" }
            fractionDigits = ""
            return nil

        case .delete:
            if let fraction = fractionDigits {
                if fraction.isEmpty {
                    fractionDigits = nil
                    if integerDigits == "0" { integerDigits = "" }
                } else {
                    fractionDigits = String(fraction.dropLast())
                }
                return nil
            }
            guard !integerDigits.isEmpty else { return .nothingToDelete }
            integerDigits.removeLast()
            return nil

        case .clear:
            guard !isEmpty else { return .nothingToDelete }
            integerDigits = ""
            fractionDigits = nil
            return nil
        }
    }

    /// What the person typed, localised: grouping separators, the locale's decimal
    /// separator, and the currency symbol on the correct side. "12." stays "$12.".
    func displayText(locale: Locale = .autoupdatingCurrent) -> String {
        let affixes = CurrencyAffixes(currency: currency, locale: locale)
        let integerValue = Decimal(string: integerDigits.isEmpty ? "0" : integerDigits) ?? 0
        var body = integerValue.formatted(.number.locale(locale).grouping(.automatic).precision(.fractionLength(0)))
        if let fraction = fractionDigits {
            body += (locale.decimalSeparator ?? ".") + fraction
        }
        return affixes.prefix + body + affixes.suffix
    }
}

/// Where a locale places the currency symbol, derived by formatting a sample value.
nonisolated struct CurrencyAffixes: Equatable, Sendable {
    let prefix: String
    let suffix: String

    init(currency: CurrencyCode, locale: Locale) {
        let sample = Decimal(1).formatted(
            .currency(code: currency.rawValue).locale(locale).precision(.fractionLength(0))
        )
        if let range = sample.range(of: "1") {
            prefix = String(sample[sample.startIndex..<range.lowerBound])
            suffix = String(sample[range.upperBound...])
        } else {
            prefix = ""
            suffix = " " + currency.rawValue
        }
    }
}
