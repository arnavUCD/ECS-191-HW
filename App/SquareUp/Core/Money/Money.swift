import Foundation

/// An exact monetary amount in a specific currency.
///
/// ## Representation
/// - In memory, `amount` is a `Decimal` that is always quantised to the currency's
///   minor unit (cents for USD). Construction rounds with `.plain` (half away from zero).
/// - On disk and over the wire, money is stored as an integer count of minor units plus an
///   ISO 4217 code (`minorUnits`, `currency`). `Codable` uses that form so JSON never
///   round-trips an amount through `Double`.
///
/// Arithmetic between different currencies is a programming error and traps; Square Up
/// does not convert currencies.
nonisolated struct Money: Hashable, Sendable {
    let amount: Decimal
    let currency: CurrencyCode

    init(_ amount: Decimal, _ currency: CurrencyCode = .usd) {
        self.amount = amount.rounded(scale: currency.minorUnitDigits, mode: .plain)
        self.currency = currency
    }

    init(minorUnits: Int64, currency: CurrencyCode = .usd) {
        self.init(Decimal(minorUnits) * currency.minorUnit, currency)
    }

    /// Parses a plain decimal string such as `"12.50"` (POSIX format, not locale-aware).
    /// Use `MoneyFormatting.parse` for user-facing, locale-aware input.
    init?(string: String, currency: CurrencyCode = .usd) {
        guard let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        self.init(value, currency)
    }

    static func zero(_ currency: CurrencyCode = .usd) -> Money {
        Money(0, currency)
    }

    var minorUnits: Int64 {
        var scaled = amount
        for _ in 0..<currency.minorUnitDigits { scaled *= 10 }
        return scaled.rounded(scale: 0, mode: .plain).int64Value
    }

    var isZero: Bool { amount == 0 }
    var isPositive: Bool { amount > 0 }
    var isNegative: Bool { amount < 0 }
    var magnitude: Money { Money(amount < 0 ? -amount : amount, currency) }

    static prefix func - (value: Money) -> Money {
        Money(-value.amount, value.currency)
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot add \(lhs.currency) and \(rhs.currency)")
        return Money(lhs.amount + rhs.amount, lhs.currency)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot subtract \(rhs.currency) from \(lhs.currency)")
        return Money(lhs.amount - rhs.amount, lhs.currency)
    }

    static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }
}

nonisolated extension Money: Comparable {
    static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currency == rhs.currency, "Cannot compare \(lhs.currency) and \(rhs.currency)")
        return lhs.amount < rhs.amount
    }
}

nonisolated extension Money: Codable {
    private enum CodingKeys: String, CodingKey {
        case minorUnits
        case currency
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try container.decode(CurrencyCode.self, forKey: .currency)
        let minorUnits = try container.decode(Int64.self, forKey: .minorUnits)
        self.init(minorUnits: minorUnits, currency: currency)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minorUnits, forKey: .minorUnits)
        try container.encode(currency, forKey: .currency)
    }
}

nonisolated extension Sequence<Money> {
    /// Sums amounts in a single currency. Returns zero in `currency` for an empty sequence.
    func sum(in currency: CurrencyCode) -> Money {
        reduce(.zero(currency), +)
    }
}
