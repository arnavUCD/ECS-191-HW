import Foundation
@testable import SquareUp
import Testing

/// Phone numbers for sign-in: E.164 for several countries (no country assumed), what counts as
/// incomplete or invalid, pasted international numbers, and formatting as typed. Numbers are
/// fictional: Firebase-style test numbers, ACMA's drama range, and libphonenumber's example numbers.
@Suite("Phone numbers · validation and E.164")
@MainActor
struct PhoneNumbersTests {
    private let numbers = PhoneNumbers.shared

    private func region(_ code: String) throws -> PhoneRegion { try #require(numbers.region(code)) }

    @Test func validNumbersBecomeE164InTheirOwnCountry() throws {
        #expect(try numbers.check("(650) 555-3434", region: region("US")) == .valid(e164: "+16505553434"))
        #expect(try numbers.check("07400 123456", region: region("GB")) == .valid(e164: "+447400123456"))
        #expect(try numbers.check("0491 570 156", region: region("AU")) == .valid(e164: "+61491570156"))
        #expect(try numbers.check("98765 43210", region: region("IN")) == .valid(e164: "+919876543210"))
    }

    @Test func aNumberWithItsOwnCountryCodeWinsOverThePickedCountry() throws {
        #expect(try numbers.check("+44 7400 123456", region: region("US")) == .valid(e164: "+447400123456"))
        #expect(try numbers.check("0044 7400 123456", region: region("US")) == .valid(e164: "+447400123456"))
        #expect(numbers.regionOfInternational("+44 7400 123456")?.code == "GB")
        #expect(numbers.regionOfInternational("650 555 3434") == nil, "Only a leading + chooses the country")
    }

    @Test func emptyShortAndWrongNumbersAreExplainedNotSent() throws {
        let us = try region("US")
        #expect(numbers.check("", region: us) == .empty)
        #expect(numbers.check("  ", region: us) == .empty)
        #expect(numbers.check("650 55", region: us) == .incomplete)
        #expect(numbers.check("123 456 7890", region: us) == .invalid, "No US area code starts with 1")
        #expect(numbers.check("650 555 3434 99999", region: us) == .invalid)
        #expect(numbers.check("650 555 3434", region: us).e164 == "+16505553434")
    }

    @Test func formattingFollowsTheCountryAsPeopleType() throws {
        let us = try region("US")
        #expect(numbers.formatPartial("6505553434", region: us) == "(650) 555-3434")
        #expect(numbers.formatPartial("650555", region: us).filter(\.isNumber) == "650555")
        #expect(numbers.display("+447400123456") == "+44 7400 123456")
    }

    @Test func dialableKeepsDigitsAndALeadingPlusOnly() {
        #expect(PhoneNumbers.dialable(" (650) 555-3434 ") == "6505553434")
        #expect(PhoneNumbers.dialable("+44 (0) 7700-900.123") == "+4407700900123")
        #expect(PhoneNumbers.dialable("0044 7700") == "+447700")
        #expect(PhoneNumbers.dialable("abc") == "")
        #expect(PhoneNumbers.masked("+16505553434") == "•••• 34")
    }

    @Test func everyCountryIsOfferedNotJustOne() throws {
        #expect(numbers.regions.count > 200)
        #expect(numbers.regions.contains { $0.code == "GB" && $0.callingCode == 44 })
        #expect(numbers.regions.allSatisfy { $0.code.count == 2 })
        #expect(try region("GB").prefix == "+44")
        #expect(try region("GB").flag == "🇬🇧")
        #expect(numbers.region("ZZ") == nil)
    }
}
