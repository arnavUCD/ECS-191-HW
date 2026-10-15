import Foundation
import PhoneNumberKit

/// A country or region a phone number can belong to ("United Kingdom", +44).
nonisolated struct PhoneRegion: Hashable, Identifiable, Sendable {
    /// ISO 3166 region code, e.g. `GB`.
    let code: String
    let callingCode: UInt64

    var id: String { code }
    var prefix: String { "+\(callingCode)" }

    func name(in locale: Locale = .autoupdatingCurrent) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    /// The region's flag from its two regional-indicator letters (decorative; never the only label).
    var flag: String {
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "" }
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// What a typed phone number is, before anything is sent.
nonisolated enum PhoneNumberCheck: Equatable, Sendable {
    case empty
    /// Too short (or too long) for the chosen country; keep typing.
    case incomplete
    /// Not a number that country uses.
    case invalid
    /// Ready: the number in E.164 (`+447700900123`), the only form ever stored or sent.
    case valid(e164: String)

    var e164: String? {
        if case .valid(let number) = self { number } else { nil }
    }
}

/// Phone numbers for sign-in: countries, formatting as people type, validation, and E.164 —
/// from libphonenumber's metadata (PhoneNumberKit), so no country is assumed. Square Up never
/// logs a phone number; Firebase does the actual verification.
@MainActor
final class PhoneNumbers {
    static let shared = PhoneNumbers()

    private let utility = PhoneNumberUtility()
    private var formatters: [String: PartialFormatter] = [:]

    /// Every region libphonenumber knows (not the `001` non-geographic ones), sorted by name.
    private(set) lazy var regions: [PhoneRegion] = {
        let locale = Locale.autoupdatingCurrent
        return utility.allCountries()
            .filter { $0.count == 2 && $0 != "001" }
            .compactMap { code in utility.countryCode(for: code).map { PhoneRegion(code: code, callingCode: $0) } }
            .sorted { $0.name(in: locale).localizedStandardCompare($1.name(in: locale)) == .orderedAscending }
    }()

    func region(_ code: String) -> PhoneRegion? {
        let upper = code.uppercased()
        return utility.countryCode(for: upper).map { PhoneRegion(code: upper, callingCode: $0) }
    }

    /// The iPhone's own region when libphonenumber supports it; otherwise the US, which people
    /// can change with the country picker.
    var defaultRegion: PhoneRegion {
        Locale.autoupdatingCurrent.region.flatMap { region($0.identifier) } ?? region("US") ?? PhoneRegion(code: "US", callingCode: 1)
    }

    /// The number as it's being typed, grouped the way that country writes it ("(650) 555-34").
    func formatPartial(_ text: String, region: PhoneRegion) -> String {
        let digits = Self.dialable(text)
        guard !digits.isEmpty else { return "" }
        return formatter(for: region.code).formatPartial(digits)
    }

    /// A number typed or pasted with its own `+` country code chooses that country.
    func regionOfInternational(_ text: String) -> PhoneRegion? {
        let digits = Self.dialable(text)
        guard digits.hasPrefix("+"), let number = try? utility.parse(digits, ignoreType: true),
              let code = utility.getRegionCode(of: number) else { return nil }
        return region(code)
    }

    func check(_ text: String, region: PhoneRegion) -> PhoneNumberCheck {
        let digits = Self.dialable(text)
        if digits.isEmpty || digits == "+" { return .empty }
        if let number = try? utility.parse(digits, withRegion: region.code) {
            return .valid(e164: utility.format(number, toType: .e164))
        }
        let national = digits.filter(\.isNumber)
        let lengths = utility.possiblePhoneNumberLengths(forCountry: region.code, phoneNumberType: .mobile, lengthType: .national)
        if let shortest = lengths.min(), national.count < shortest, !digits.hasPrefix("+") { return .incomplete }
        return .invalid
    }

    /// An E.164 number written for people ("+44 7700 900123").
    func display(_ e164: String) -> String {
        guard let number = try? utility.parse(e164, ignoreType: true) else { return e164 }
        return utility.format(number, toType: .international)
    }

    /// An example of the country's mobile numbers, as a placeholder.
    func placeholder(for region: PhoneRegion) -> String {
        utility.getFormattedExampleNumber(forCountry: region.code, ofType: .mobile, withFormat: .national, withPrefix: false) ?? ""
    }

    private func formatter(for region: String) -> PartialFormatter {
        if let existing = formatters[region] { return existing }
        let created = PartialFormatter(utility: utility, defaultRegion: region, withPrefix: true)
        formatters[region] = created
        return created
    }

    /// Digits, plus a leading `+` if the person typed one (or the international `00`); spaces,
    /// dashes, dots, and brackets dropped.
    nonisolated static func dialable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if trimmed.hasPrefix("+") { return "+" + digits }
        if trimmed.hasPrefix("00"), digits.count > 2 { return "+" + digits.dropFirst(2) }
        return digits
    }

    /// Only the last two digits, for places that confirm a number without showing it ("•• 23").
    nonisolated static func masked(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        guard digits.count > 2 else { return "••" }
        return "•••• " + digits.suffix(2)
    }
}
