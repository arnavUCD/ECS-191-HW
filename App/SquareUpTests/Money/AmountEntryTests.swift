import Foundation
@testable import SquareUp
import Testing

@Suite("Amount entry keypad")
struct AmountEntryTests {
    private func typed(_ keys: [AmountEntry.Key], currency: CurrencyCode = .usd) -> AmountEntry {
        var entry = AmountEntry(currency: currency)
        for key in keys { entry.apply(key) }
        return entry
    }

    @Test("Digits and decimal produce an exact amount")
    func typing() {
        let entry = typed([.digit(4), .digit(2), .decimalSeparator, .digit(5)])
        #expect(entry.money == Money(Decimal(string: "42.5")!))
        #expect(entry.displayText(locale: Locale(identifier: "en_US")) == "$42.5")
    }

    @Test("A trailing separator is displayed faithfully")
    func trailingSeparator() {
        let entry = typed([.digit(1), .digit(2), .decimalSeparator])
        #expect(entry.displayText(locale: Locale(identifier: "en_US")) == "$12.")
        #expect(entry.money == Money(12))
    }

    @Test("Leading separator inserts a zero; leading zero is replaced")
    func leadingZero() {
        #expect(typed([.decimalSeparator, .digit(5)]).money == Money(Decimal(string: "0.5")!))
        #expect(typed([.digit(0), .digit(7)]).integerDigits == "7")
    }

    @Test("Rejects a third decimal digit for USD")
    func fractionLimit() {
        var entry = typed([.digit(1), .decimalSeparator, .digit(2), .digit(3)])
        #expect(entry.apply(.digit(4)) == .tooManyFractionDigits)
        #expect(entry.money == Money(Decimal(string: "1.23")!))
    }

    @Test("JPY has no decimal separator")
    func yen() {
        var entry = typed([.digit(9)], currency: .jpy)
        #expect(entry.apply(.decimalSeparator) == .separatorNotAllowed)
    }

    @Test("Rejects digits beyond the per-expense maximum")
    func maximum() {
        var entry = AmountEntry(currency: .usd, maximum: Money(100))
        entry.apply(.digit(9))
        entry.apply(.digit(9))
        #expect(entry.apply(.digit(9)) == .exceedsMaximum)
        #expect(entry.money == Money(99))
    }

    @Test("Delete walks back through fraction, separator, and integer digits")
    func delete() {
        var entry = typed([.digit(3), .decimalSeparator, .digit(1)])
        entry.apply(.delete)
        #expect(entry.fractionDigits == "")
        entry.apply(.delete)
        #expect(entry.fractionDigits == nil)
        entry.apply(.delete)
        #expect(entry.isEmpty)
        #expect(entry.apply(.delete) == .nothingToDelete)
    }

    @Test("Prefilling from money round-trips", arguments: ["12.50", "0.07", "1000", "999999.99"])
    func prefill(value: String) {
        let money = Money(string: value)!
        #expect(AmountEntry(money: money).money == money)
    }

    @Test("German display uses a comma and trailing symbol")
    func germanDisplay() {
        var entry = AmountEntry(currency: .eur)
        for key: AmountEntry.Key in [.digit(1), .digit(2), .digit(3), .digit(4), .decimalSeparator, .digit(5)] { entry.apply(key) }
        let text = entry.displayText(locale: Locale(identifier: "de_DE"))
        #expect(text.hasPrefix("1.234,5"))
        #expect(text.hasSuffix("€"))
    }
}
