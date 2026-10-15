import Foundation

/// A monetary amount read from receipt text.
nonisolated struct ParsedAmount: Hashable, Sendable {
    let money: Money
    /// The separator could be read two ways (e.g. "12,50" on a dollar receipt).
    let isAmbiguous: Bool
    /// The token carried an explicit currency symbol or code.
    let currency: CurrencyCode?
}

/// Deterministic money parsing for receipt text (milestone 3 §7, §17.2 "Money parsing").
///
/// Rules:
/// - Digits are converted straight to integer minor units; no floating point, no rounding.
/// - An amount must show exactly the currency's minor-unit digits ("12.5" is not $12.50 —
///   recognition never invents a digit). Zero-digit currencies accept whole numbers.
/// - Thousands separators are accepted only in valid positions ("1,234.56", "1.234,56").
/// - Negative forms: "-3.00", "3.00-", "(3.00)", "3.00 CR".
nonisolated enum ReceiptAmountParser {
    static let symbols: [Character: CurrencyCode] = ["$": .usd, "€": .eur, "£": .gbp, "¥": .jpy, "₹": .inr]
    static let codes: Set<String> = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "INR", "MXN", "NZD", "CHF"]
    /// Currencies printed with "$"; a "$" on the receipt is consistent with any of them.
    static let dollarCurrencies: Set<String> = ["USD", "CAD", "AUD", "NZD", "MXN", "SGD", "HKD"]

    /// Parses one token such as "$12.50", "(3.00)", "1,234.56", or "12,50".
    static func parse(_ token: String, currency: CurrencyCode) -> ParsedAmount? {
        var text = token.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var isNegative = false
        var detected: CurrencyCode?

        if text.uppercased().hasSuffix("CR") {
            isNegative = true
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("("), text.hasSuffix(")") {
            isNegative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("-") {
            isNegative = true
            text.removeFirst()
        }
        if text.hasSuffix("-") {
            isNegative = true
            text.removeLast()
        }
        if let first = text.first, let code = symbols[first] {
            detected = code
            text.removeFirst()
        }
        if text.hasPrefix("-") {
            isNegative = true
            text.removeFirst()
        }
        let upper = text.uppercased()
        if upper.count > 3, codes.contains(String(upper.prefix(3))), !upper.dropFirst(3).contains(where: \.isLetter) {
            detected = CurrencyCode(String(upper.prefix(3)))
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first, first.isNumber, let last = text.last, last.isNumber else { return nil }
        guard let (units, ambiguous) = minorUnits(text, digits: currency.minorUnitDigits) else { return nil }
        let money = Money(minorUnits: isNegative ? -units : units, currency: currency)
        return ParsedAmount(money: money, isAmbiguous: ambiguous, currency: detected)
    }

    /// The right-most amount in a line of text, and the text before it.
    static func trailingAmount(in line: String, currency: CurrencyCode) -> (amount: ParsedAmount, label: String)? {
        let tokens = line.split(separator: " ").map(String.init)
        guard var index = tokens.indices.last else { return nil }
        var credit = ""
        if tokens[index].uppercased() == "CR", index > 0 {
            credit = "CR"
            index -= 1
        }
        while index >= 0 {
            var candidate = tokens[index]
            var start = index
            // OCR often separates a symbol or minus from its digits ("$ 12.50", "- 3.00").
            while start > 0, ["$", "€", "£", "¥", "₹", "-"].contains(tokens[start - 1]) {
                candidate = tokens[start - 1] + candidate
                start -= 1
            }
            if let amount = parse(candidate + credit, currency: currency) {
                return (amount, tokens[..<start].joined(separator: " "))
            }
            // Look past short trailing markers only, such as "T" (taxable) or "F" (food).
            guard tokens[index].count <= 2, tokens[index].allSatisfy(\.isLetter) else { return nil }
            index -= 1
        }
        return nil
    }

    /// Currencies indicated anywhere in the text.
    static func currencies(in text: String) -> Set<String> {
        var found = Set<String>()
        for character in text {
            if let code = symbols[character] {
                found.insert(code == .usd ? "$" : code.rawValue)
            }
        }
        for word in text.uppercased().split(whereSeparator: { !$0.isLetter }) where codes.contains(String(word)) {
            found.insert(String(word))
        }
        return found
    }

    // MARK: - Digits

    private static func minorUnits(_ text: String, digits: Int) -> (Int64, Bool)? {
        guard text.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else { return nil }
        if digits == 0 {
            // "1,200" or "1200" (no decimal part allowed).
            guard let whole = groupedInteger(text, separator: ",") ?? groupedInteger(text, separator: ".") else { return nil }
            return (whole, false)
        }
        guard let separatorIndex = text.lastIndex(where: { $0 == "." || $0 == "," }) else { return nil }
        let fraction = text[text.index(after: separatorIndex)...]
        guard fraction.count == digits, let fractionValue = Int64(fraction) else { return nil }
        let integerPart = String(text[..<separatorIndex])
        let decimalSeparator = text[separatorIndex]
        let grouping: Character = decimalSeparator == "." ? "," : "."
        let ambiguous = decimalSeparator == "," && !integerPart.contains(".")
        guard let whole = integerPart.isEmpty ? 0 : groupedInteger(integerPart, separator: grouping) else { return nil }
        var scale: Int64 = 1
        for _ in 0..<digits { scale *= 10 }
        let (product, overflow) = whole.multipliedReportingOverflow(by: scale)
        guard !overflow else { return nil }
        return (product + fractionValue, ambiguous)
    }

    /// "1,234" with grouping in valid positions, or plain digits.
    private static func groupedInteger(_ text: String, separator: Character) -> Int64? {
        let groups = text.split(separator: separator, omittingEmptySubsequences: false)
        guard let first = groups.first, !first.isEmpty, first.allSatisfy(\.isNumber) else { return nil }
        if groups.count > 1 {
            guard first.count <= 3, groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
        }
        guard text.count <= 15 else { return nil }
        return Int64(groups.joined())
    }
}
