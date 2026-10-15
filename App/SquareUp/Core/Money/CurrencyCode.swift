import Foundation

/// An ISO 4217 currency code and the number of minor-unit digits Square Up uses for it.
///
/// The minor-unit table is explicit rather than derived from a formatter so that stored
/// amounts and split math never change when a device's locale data changes.
nonisolated struct CurrencyCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    init(_ code: String) {
        self.init(rawValue: code)
    }

    static let usd = CurrencyCode("USD")
    static let eur = CurrencyCode("EUR")
    static let gbp = CurrencyCode("GBP")
    static let inr = CurrencyCode("INR")
    static let jpy = CurrencyCode("JPY")
    static let kwd = CurrencyCode("KWD")

    /// ISO 4217 exponent: digits after the decimal separator in the smallest unit.
    var minorUnitDigits: Int {
        switch rawValue {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
             "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF":
            0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            3
        default:
            2
        }
    }

    /// The value of one minor unit, e.g. 0.01 for USD.
    var minorUnit: Decimal {
        var unit = Decimal(1)
        for _ in 0..<minorUnitDigits { unit /= 10 }
        return unit
    }

    var description: String { rawValue }
}
