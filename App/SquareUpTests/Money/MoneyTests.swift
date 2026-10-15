import Foundation
@testable import SquareUp
import Testing

@Suite("Money")
struct MoneyTests {
    @Test("Construction quantises to the currency's minor unit, half away from zero",
          arguments: [
              ("12.345", "12.35"), ("12.344", "12.34"), ("0.005", "0.01"), ("-0.005", "-0.01"), ("7", "7"),
          ])
    func quantises(input: String, expected: String) throws {
        let money = try #require(Money(string: input))
        #expect(money.amount == Decimal(string: expected))
    }

    @Test("Minor units honour ISO 4217 exponents")
    func minorUnits() {
        #expect(Money(Decimal(string: "12.34")!, .usd).minorUnits == 1234)
        #expect(Money(1200, .jpy).minorUnits == 1200)
        #expect(Money(Decimal(string: "1.234")!, .kwd).minorUnits == 1234)
        #expect(Money(minorUnits: 1999, currency: .usd).amount == Decimal(string: "19.99"))
        #expect(Money(Decimal(string: "12.6")!, .jpy).amount == 13)
    }

    @Test("Decimal arithmetic stays exact where Double would not")
    func exactArithmetic() {
        let tenCents = Money(Decimal(string: "0.1")!)
        let twentyCents = Money(Decimal(string: "0.2")!)
        #expect(tenCents + twentyCents == Money(Decimal(string: "0.3")!))
        let sum = Array(repeating: tenCents, count: 10).sum(in: .usd)
        #expect(sum == Money(1))
    }

    @Test("Sign helpers and magnitude")
    func signs() {
        let negative = -Money(Decimal(string: "4.50")!)
        #expect(negative.isNegative)
        #expect(negative.magnitude == Money(Decimal(string: "4.50")!))
        #expect(Money.zero().isZero)
        #expect(Money(1) > Money(Decimal(string: "0.99")!))
    }

    @Test("Codable uses integer minor units, never a floating-point number")
    func codableRoundTrip() throws {
        let original = Money(Decimal(string: "1234567.89")!, .usd)
        let data = try JSONEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"minorUnits\":123456789"))
        #expect(json.contains("\"currency\":\"USD\""))
        #expect(try JSONDecoder().decode(Money.self, from: data) == original)
    }

    @Test("Currency codes normalise case and know their minor unit")
    func currencyCodes() {
        #expect(CurrencyCode("usd") == .usd)
        #expect(CurrencyCode.usd.minorUnit == Decimal(string: "0.01"))
        #expect(CurrencyCode.jpy.minorUnit == 1)
        #expect(CurrencyCode.kwd.minorUnitDigits == 3)
    }

    @Test("Significant fraction digits")
    func fractionDigits() {
        #expect(Decimal(string: "12.50")!.significantFractionDigits == 1)
        #expect(Decimal(string: "12.505")!.significantFractionDigits == 3)
        #expect(Decimal(12).significantFractionDigits == 0)
    }
}

@Suite("Money formatting and parsing")
struct MoneyFormattingTests {
    let us = Locale(identifier: "en_US")
    let germany = Locale(identifier: "de_DE")

    @Test("Formats with minor-unit precision per locale")
    func formats() {
        #expect(MoneyFormatting.string(Money(Decimal(string: "1234.5")!), locale: us) == "$1,234.50")
        #expect(MoneyFormatting.string(Money(1200, .jpy), locale: us) == "¥1,200")
        let euro = MoneyFormatting.string(Money(Decimal(string: "1234.5")!, .eur), locale: germany)
        #expect(euro.contains("1.234,50"))
        #expect(euro.contains("€"))
    }

    @Test("Formats magnitude only; direction is a separate decision")
    func magnitude() {
        #expect(MoneyFormatting.string(-Money(5), locale: us) == "$5.00")
    }

    @Test("Signed strings use explicit glyphs and leave zero unsigned")
    func signed() {
        #expect(MoneyFormatting.signedString(Money(12), locale: us) == "+$12.00")
        #expect(MoneyFormatting.signedString(-Money(Decimal(string: "4.5")!), locale: us) == "\u{2212}$4.50")
        #expect(MoneyFormatting.signedString(.zero(), locale: us) == "$0.00")
    }

    @Test("Spoken strings name the currency")
    func spoken() {
        let spoken = MoneyFormatting.spokenString(Money(Decimal(string: "42.50")!), locale: us)
        #expect(spoken.localizedCaseInsensitiveContains("dollar"))
    }

    @Test("Parses locale-aware input", arguments: [
        ("1,234.50", "1234.50"), ("$12", "12"), ("0.99", "0.99"), ("  7 ", "7"),
    ])
    func parses(text: String, expected: String) throws {
        let money = try #require(MoneyFormatting.parse(text, currency: .usd, locale: us))
        #expect(money.amount == Decimal(string: expected))
    }

    @Test("Parses German decimal comma")
    func parsesGerman() throws {
        let money = try #require(MoneyFormatting.parse("12,50", currency: .eur, locale: germany))
        #expect(money.amount == Decimal(string: "12.5"))
    }

    @Test("Rejects empty, negative, and non-numeric input", arguments: ["", "abc", "-5", "   "])
    func rejects(text: String) {
        #expect(MoneyFormatting.parse(text, currency: .usd, locale: us) == nil)
    }
}
