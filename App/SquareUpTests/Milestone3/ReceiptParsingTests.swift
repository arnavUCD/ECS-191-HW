import Foundation
@testable import SquareUp
import Testing

@Suite("M3 receipt parsing and structuring")
struct ReceiptParsingTests {

    // MARK: Money

    @Test("Amounts parse to exact minor units", arguments: [
        ("12.50", 1250), ("$12.50", 1250), ("1,234.56", 123_456), ("-3.00", -300), ("3.00-", -300), ("(3.00)", -300),
        ("$-4.00", -400), ("0.99", 99), ("12,50", 1250), ("1.234,56", 123_456), ("2.00CR", -200),
    ])
    func amounts(text: String, units: Int64) {
        #expect(ReceiptAmountParser.parse(text, currency: .usd)?.money.minorUnits == units)
    }

    @Test("Text that isn't an exact amount is rejected, never padded or rounded", arguments: [
        "12.5", "12", "12.505", "1,23.45", "8.25%", "09/24/2026", "7:42", "555-0136", "****4821", "abc", "", "12.50.00",
    ])
    func rejected(text: String) {
        #expect(ReceiptAmountParser.parse(text, currency: .usd) == nil)
    }

    @Test("Comma decimals are flagged ambiguous; zero-digit currencies accept whole numbers")
    func ambiguityAndYen() {
        #expect(ReceiptAmountParser.parse("12,50", currency: .usd)?.isAmbiguous == true)
        #expect(ReceiptAmountParser.parse("12.50", currency: .usd)?.isAmbiguous == false)
        #expect(ReceiptAmountParser.parse("1,200", currency: .jpy)?.money == Money(1200, .jpy))
        #expect(ReceiptAmountParser.parse("¥980", currency: .jpy)?.currency == .jpy)
        #expect(ReceiptAmountParser.parse("12.50", currency: .jpy) == nil)
    }

    @Test("Trailing amounts skip tax markers and join split symbols")
    func trailing() throws {
        let marked = try #require(ReceiptAmountParser.trailingAmount(in: "Truffle Fries 9.50 T", currency: .usd))
        #expect(marked.amount.money.minorUnits == 950)
        #expect(marked.label == "Truffle Fries")
        let split = try #require(ReceiptAmountParser.trailingAmount(in: "Coupon - $ 2.00", currency: .usd))
        #expect(split.amount.money.minorUnits == -200)
        #expect(ReceiptAmountParser.trailingAmount(in: "Guests 4", currency: .usd) == nil)
    }

    // MARK: Dates, labels, quantities

    @Test("Dates: US default, unambiguous day-first, ISO, and month names")
    func dates() {
        let calendar = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }()
        func ymd(_ text: String) -> [Int]? {
            ReceiptDateParser.date(in: text, timeZone: .gmt, dayFirst: false).map {
                let parts = calendar.dateComponents([.year, .month, .day], from: $0.date)
                return [parts.year!, parts.month!, parts.day!]
            }
        }
        #expect(ymd("09/24/2026 7:42 PM") == [2026, 9, 24])
        #expect(ymd("24/09/2026") == [2026, 9, 24])
        #expect(ymd("2026-09-24") == [2026, 9, 24])
        #expect(ymd("Sep 24, 2026") == [2026, 9, 24])
        #expect(ymd("24 September 2026") == [2026, 9, 24])
        #expect(ymd("02/30/2026") == nil)
        #expect(ReceiptDateParser.date(in: "03/04/2026", timeZone: .gmt, dayFirst: false)?.isAmbiguous == true)
        #expect(ReceiptDateParser.date(in: "09/24/2026", timeZone: .gmt, dayFirst: false)?.isAmbiguous == false)
    }

    @Test("Summary, payment, and noise labels", arguments: [
        ("SUBTOTAL", ReceiptLineRole.subtotal), ("Sub-total", .subtotal), ("TOTAL", .total), ("Amount Due", .total),
        ("Sales Tax 8.25%", .tax), ("VAT", .tax), ("Tax included", .taxIncluded), ("Tip", .tip), ("Gratuity", .tip),
        ("Suggested tip 18%", .excluded), ("Service Charge 18%", .serviceCharge), ("Delivery Fee", .fee),
        ("Happy Hour Discount", .discount), ("Coupon", .discount), ("Rounding", .rounding), ("VISA ****4821", .excluded),
        ("CHANGE", .payment), ("Cash", .payment), ("Table 12", .excluded), ("(530) 555-0136", .excluded),
        ("418 Example Ave", .excluded), ("Truffle Fries", .item), ("Total items 8", .excluded), ("You saved", .excluded),
    ])
    func labels(text: String, role: ReceiptLineRole) {
        #expect(ReceiptLineClassifier.role(of: text) == role)
    }

    @Test("Quantities and unit prices")
    func quantities() {
        let pizza = ReceiptLineClassifier.quantityAndName(from: "2 Margherita Pizza @ 8.00", currency: .usd)
        #expect(pizza.quantity == 2)
        #expect(pizza.unitPrice == Money(8))
        #expect(pizza.name == "Margherita Pizza")
        let times = ReceiptLineClassifier.quantityAndName(from: "Lemonade 3 x 2.25", currency: .usd)
        #expect(times.quantity == 3)
        #expect(times.unitPrice == Money(2.25))
        #expect(times.name == "Lemonade")
        let plain = ReceiptLineClassifier.quantityAndName(from: "Tex Mex Bowl", currency: .usd)
        #expect(plain.quantity == nil)
        #expect(plain.name == "Tex Mex Bowl")
    }

    // MARK: Layout

    @Test("Rows group by geometry regardless of input order; stacked text starts a new row")
    func rows() {
        let regions = ReceiptFixtures.regions([("1 Tiramisu", "8.50"), ("1 Iced Tea", "3.25")])
        let lines = ReceiptTextLayout.lines(from: regions.reversed(), pageOrder: [ReceiptFixtures.pageID])
        #expect(lines.map(\.text) == ["1 Tiramisu 8.50", "1 Iced Tea 3.25"])
        // A slightly skewed amount (half a line lower) still joins its label.
        var skewed = regions
        let amount = skewed[1]
        skewed[1] = RecognizedRegion(id: amount.id, pageID: amount.pageID, text: amount.text, confidence: 1,
                                     bounds: ReceiptRect(x: 0.8, y: amount.bounds.y + 0.008, width: 0.12, height: 0.02), readingOrder: 1)
        #expect(ReceiptTextLayout.lines(from: skewed, pageOrder: [ReceiptFixtures.pageID]).first?.text == "1 Tiramisu 8.50")
    }

    // MARK: Structuring

    @Test("The dinner receipt structures completely and reconciles exactly")
    func dinner() {
        let draft = ReceiptFixtures.draft(ReceiptFixtures.dinner)
        #expect(draft.merchant.value == "FERNWOOD SUPPER CLUB")
        #expect(draft.merchant.attention == .looksGood)
        #expect(draft.items.map(\.name.value) == ["Truffle Fries", "Margherita Pizza", "Caesar Salad", "Lemonade", "Mushroom Risotto",
                                                  "Shared Nachos", "Tiramisu", "Iced Tea"])
        #expect(draft.items[1].quantity == 2)
        #expect(draft.items[1].unitPrice == Money(8))
        #expect(draft.charges.map(\.kind) == [.discount, .tax, .tip])
        #expect(draft.charges[0].value == Money(-4))
        #expect(draft.total.value == Money(104.04))
        #expect(draft.total.attention == .looksGood)
        #expect(draft.subtotal.value == Money(86.25))
        #expect(draft.date.attention == .looksGood)
        let reconciliation = ReceiptValidator.reconcile(draft)
        #expect(reconciliation.isReconciled)
        #expect(reconciliation.canConfirm)
        #expect(ReceiptLanguage.reviewStatement(reconciliation, locale: Locale(identifier: "en_US"))
            == "The receipt total is $104.04. 8 items and 3 additional charges account for the full amount.")
        // Every proposed value points back at its evidence.
        #expect(draft.items.allSatisfy { !$0.sourceRegionIDs.isEmpty })
        #expect(draft.items.allSatisfy { $0.sourceRegionIDs.allSatisfy { id in draft.region(id) != nil } })
        // Card numbers, phone numbers, addresses, and table text never become items.
        #expect(!draft.items.contains { $0.name.value.contains("4821") || $0.name.value.contains("Table") })
    }

    @Test("The bundled recognition fixture carries one misreading that blocks until corrected")
    func bundledFixture() async throws {
        let regions = try await ReceiptFixtures.bundledRegions()
        var draft = ReceiptDraft.empty(pages: [ReceiptFixtures.page(source: .sample)], currency: .usd, date: DemoScenario.fixedReferenceDate)
        draft.regions = regions
        draft = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: draft.pages, regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate, idSeed: ReceiptFixtures.seed
        )).applied(to: draft)
        let tiramisu = try #require(draft.items.first { $0.name.value == "Tiramisu" })
        #expect(tiramisu.amount == Money(6.50))
        #expect(tiramisu.lineTotal.attention == .check)
        #expect(tiramisu.lineTotal.reason == .lowConfidence)
        #expect(draft.total.value == Money(104.04))
        #expect(draft.total.attention == .check, "Two printed totals and neither matches the misread lines")
        let before = ReceiptValidator.reconcile(draft)
        #expect(before.difference == Money(2))
        #expect(!before.canConfirm)
        #expect(before.issues.contains { $0.kind == .subtotalMismatch(printed: Money(86.25), items: Money(84.25)) })

        // The person corrects the line from the evidence; nothing else changes.
        let index = try #require(draft.items.firstIndex { $0.id == tiramisu.id })
        draft.items[index].lineTotal.edit(Money(8.50), by: People.riley, at: DemoScenario.fixedReferenceDate)
        #expect(draft.items[index].lineTotal.proposed == Money(6.50), "The original proposal is preserved")
        let after = ReceiptValidator.reconcile(draft)
        #expect(after.isReconciled)
        #expect(after.canConfirm)
    }

    @Test("Structuring is deterministic, including identifiers")
    func deterministic() {
        #expect(ReceiptFixtures.propose(ReceiptFixtures.dinner) == ReceiptFixtures.propose(ReceiptFixtures.dinner))
    }

    @Test("Refunds, zero-value lines, duplicates, and long names")
    func itemEdgeCases() {
        let long = String(repeating: "Extremely Long Seasonal Tasting Flight ", count: 4).trimmingCharacters(in: .whitespaces)
        let draft = ReceiptFixtures.draft([
            ("Corner Market", nil), ("Oat Milk", "4.99"), ("Oat Milk", "4.99"), ("RETURN Oat Milk", "-4.99"), ("Promo Sticker", "0.00"),
            (long, "12.00"), ("SUBTOTAL", "16.99"), ("TOTAL", "16.99"),
        ])
        #expect(draft.items.count == 5)
        #expect(draft.items[1].lineTotal.reason == .possibleDuplicate)
        #expect(draft.items[2].isRefund)
        #expect(draft.items[2].amount == Money(-4.99))
        #expect(draft.items[3].isNote)
        #expect(draft.items[4].name.value == long)
        let reconciliation = ReceiptValidator.reconcile(draft)
        #expect(reconciliation.isReconciled)
        #expect(reconciliation.warnings.contains { $0.kind == .possibleDuplicate(draft.items[1].id) })
        #expect(reconciliation.itemCount == 4, "Zero-value lines are notes, not chargeable items")
    }

    @Test("Service charge plus tip, multiple discounts, and printed rounding")
    func chargeEdgeCases() {
        let draft = ReceiptFixtures.draft([
            ("Harbor Noodle House", nil), ("Dumplings", "10.00"), ("Noodles", "14.00"), ("Coupon", "-2.00"), ("SUBTOTAL", "22.00"),
            ("Loyalty discount", "1.00"), ("Service Charge 18%", "4.32"), ("Tax", "1.86"), ("Tip", "3.00"), ("Rounding", "-0.03"),
            ("TOTAL", "30.15"),
        ])
        #expect(draft.charges.map(\.kind) == [.discount, .discount, .serviceCharge, .tax, .tip, .adjustment])
        #expect(draft.charges[1].value == Money(-1), "A discount printed without a sign is stored as negative")
        #expect(ReceiptValidator.reconcile(draft).isReconciled)
    }

    @Test("Tax included, blank tip, and no total")
    func notesAndMissingValues() {
        let draft = ReceiptFixtures.draft([
            ("Bakery Nine", nil), ("Sourdough", "8.00"), ("Coffee", "4.00"), ("Tax included", "0.99"), ("Tip", nil),
        ])
        #expect(draft.recognition.notes.contains(.taxIncluded(Money(0.99))))
        #expect(draft.recognition.notes.contains(.blankTip))
        #expect(draft.charges.isEmpty)
        #expect(draft.total.value == nil)
        #expect(draft.total.attention == .needsResolution)
        let reconciliation = ReceiptValidator.reconcile(draft)
        #expect(reconciliation.blockingIssues.map(\.kind) == [.totalMissing])
    }

    @Test("Mixed currencies block until a currency is chosen")
    func mixedCurrencies() {
        var draft = ReceiptFixtures.draft([("Duty Free", nil), ("Chocolate €", "5.00"), ("Water $", "2.00"), ("TOTAL", "7.00")])
        #expect(draft.currency.attention == .needsResolution)
        #expect(ReceiptValidator.reconcile(draft).blockingIssues.contains { $0.kind == .mixedCurrencies })
        draft.currency.edit(.usd, by: People.riley, at: .now)
        #expect(!ReceiptValidator.reconcile(draft).blockingIssues.contains { $0.kind == .mixedCurrencies })
    }

    @Test("No text and unreadable lines produce an empty, reviewable proposal")
    func noText() {
        let proposal = ReceiptFixtures.propose([])
        #expect(proposal.notes == [.noText])
        #expect(proposal.items.isEmpty)
        #expect(proposal.merchant.attention == .needsResolution)
        #expect(proposal.date.reason == .notFound)
        #expect(proposal.date.value == DemoScenario.fixedReferenceDate, "Falls back to the capture date, flagged to check")
        let handwritten = ReceiptFixtures.propose([("scribbles", nil), ("more", nil)])
        #expect(handwritten.notes.contains(.noPricedLines))
    }

    @Test("Low recognition confidence is surfaced as an action, not a number")
    func confidence() {
        let draft = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: [ReceiptFixtures.page()], regions: ReceiptFixtures.regions([("Cafe Ten", nil), ("Latte", "5.25"), ("TOTAL", "5.25")], confidence: 0.3),
            defaultCurrency: .usd, captureDate: .now, idSeed: ReceiptFixtures.seed
        ))
        #expect(draft.items.first?.lineTotal.attention == .check)
        #expect(draft.total.attention == .check)
        #expect(ReceiptLanguage.label(.check) == "Check this")
    }

    @Test("Mismatched receipt math is never corrected silently; a labelled adjustment documents it")
    func adjustment() {
        var draft = ReceiptFixtures.draft([("Food Truck", nil), ("Tacos", "9.00"), ("TOTAL", "9.02")])
        let reconciliation = ReceiptValidator.reconcile(draft)
        #expect(reconciliation.difference == Money(0.02))
        #expect(draft.total.value == Money(9.02), "The printed total is untouched")
        draft.charges.append(ReceiptCharge(kind: .adjustment, label: "", amount: .entered(Money(0.02), by: People.riley, at: .now)))
        #expect(ReceiptValidator.reconcile(draft).blockingIssues.map(\.kind).contains { if case .adjustmentLabelMissing = $0 { true } else { false } })
        draft.charges[0].label = "Card surcharge printed separately"
        #expect(ReceiptValidator.reconcile(draft).canConfirm)
    }
}
