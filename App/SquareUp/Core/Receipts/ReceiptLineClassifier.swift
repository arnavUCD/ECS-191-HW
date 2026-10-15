import Foundation

/// What a receipt row most likely is, from its label words alone.
nonisolated enum ReceiptLineRole: Hashable, Sendable {
    case item
    case subtotal
    case total
    case tax
    /// "Tax included" — informational; already inside prices.
    case taxIncluded
    case tip
    case serviceCharge
    case fee
    case discount
    case rounding
    /// Card, cash, change, authorization, and other tender lines.
    case payment
    /// Header and footer text: table numbers, phone numbers, addresses, thank-you notes.
    case excluded
}

/// Keyword and pattern rules for receipt rows (milestone 3 §6.3). Pure and table-tested.
nonisolated enum ReceiptLineClassifier {
    static func role(of label: String) -> ReceiptLineRole {
        let lower = label.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        func has(_ candidates: Set<String>) -> Bool { !words.isDisjoint(with: candidates) }
        func contains(_ phrases: [String]) -> Bool { phrases.contains { lower.contains($0) } }

        if isSensitiveOrNoise(label) || contains(["suggest", "tip guide"]) { return .excluded }
        if contains(["subtotal", "sub total", "sub-total"]) { return .subtotal }
        if has(["tip", "tips", "gratuity", "grat"]), !contains(["suggest", "guide", "included"]) { return .tip }
        if contains(["service charge", "service fee", "svc chg", "svc charge", "auto grat", "gratuity included", "included gratuity"]) {
            return .serviceCharge
        }
        if has(["saving", "savings", "you", "saved"]) && contains(["sav"]) { return .excluded }
        if has(["tax", "vat", "gst", "hst", "pst", "taxes"]) {
            return contains(["incl", "included"]) ? .taxIncluded : .tax
        }
        if has(["rounding", "rounded", "round"]) { return .rounding }
        if contains(["amount due", "balance due", "total due", "grand total", "amount owed"]) { return .total }
        if has(["total"]) {
            if has(["items", "item", "qty", "quantity", "count"]) { return .excluded }
            return .total
        }
        if has(payment) || lower.contains("balance") { return .payment }
        if has(["discount", "coupon", "promo", "promotion", "off", "comp", "complimentary", "voucher", "markdown", "reward"])
            || contains(["happy hour"]) {
            return .discount
        }
        if has(["fee", "fees", "surcharge", "delivery", "corkage", "deposit", "crv", "convenience"]) { return .fee }
        if has(header) { return .excluded }
        return .item
    }

    static let payment: Set<String> = [
        "visa", "mastercard", "mc", "amex", "discover", "debit", "credit", "card", "cash", "change", "tender", "tendered",
        "paid", "payment", "auth", "authorization", "approval", "approved", "appr", "ref", "reference", "trans", "transaction",
        "acct", "account", "chip", "contactless", "entry", "aid", "tvr", "tsi", "gift", "applepay", "pay", "signature",
    ]

    static let header: Set<String> = [
        "table", "server", "guest", "guests", "check", "chk", "order", "ticket", "terminal", "cashier", "receipt", "welcome",
        "thank", "thanks", "store", "tel", "phone", "www", "visit", "survey", "host", "station", "register", "reg", "seat",
        "covers", "copy", "customer", "merchant", "time", "date",
    ]

    /// Card numbers, authorization codes, phone numbers, addresses, URLs, and e-mail addresses are
    /// never items, merchants, or totals (milestone 3 §6.3 exclusions).
    static func isSensitiveOrNoise(_ text: String) -> Bool {
        let patterns = [
            #"[*xX•]{3,}\s?\d{4}"#, // masked card number
            #"\b\d{4}\s?[*xX•]{4,}"#,
            #"\(\d{3}\)\s?\d{3}[-.\s]\d{4}"#, // phone
            #"\b\d{3}[-.]\d{3}[-.]\d{4}\b"#,
            #"\b[A-Z]{2}\s\d{5}(-\d{4})?\b"#, // state + ZIP
            #"(?i)\b(www\.|https?://|\.com\b|\.net\b|\.org\b)"#,
            #"\S+@\S+\.\S+"#,
            #"(?i)\b\d{1,5}\s+\w+(\s\w+)?\s(st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|way|ste|suite)\b\.?"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// "2 Lemonade @ 3.50", "2x Lemonade", "Lemonade 2 @ 3.50" → quantity, unit price, clean name.
    static func quantityAndName(from label: String, currency: CurrencyCode) -> (quantity: Int?, unitPrice: Money?, name: String) {
        var name = label
        var quantity: Int?
        var unitPrice: Money?
        let atPrice = name.firstMatch(of: /(?:(\d{1,3})\s*)?@\s*[$€£]?\s*(\d[\d.,]*)\s*(?:ea|each)?\.?\s*$/)
            .map { ($0.range, $0.1, $0.2) }
        let timesPrice = name.firstMatch(of: /\b(\d{1,3})\s*[xX×]\s*[$€£]?\s*(\d+[.,]\d+)\s*(?:ea|each)?\.?\s*$/)
            .map { ($0.range, Optional($0.1), $0.2) }
        if let (range, count, priceText) = atPrice ?? timesPrice,
           let price = ReceiptAmountParser.parse(String(priceText), currency: currency) {
            unitPrice = price.money
            if let count = count.flatMap({ Int($0) }), count > 0 { quantity = count }
            name.removeSubrange(range)
        }
        if let match = name.firstMatch(of: /^\s*(\d{1,2})\s*[xX×]?\s+(?=\p{L})/) {
            if quantity == nil, let count = Int(match.1), count > 0 { quantity = count }
            name.removeSubrange(match.range)
        }
        let cleaned = name
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".:-*#")))
            .split(separator: " ").joined(separator: " ")
        return (quantity, unitPrice, cleaned)
    }

    /// Text that could be a merchant name.
    static func isMerchantCandidate(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        guard letters >= 3, Double(letters) / Double(max(text.count, 1)) >= 0.5 else { return false }
        guard !isSensitiveOrNoise(text), ReceiptDateParser.date(in: text, timeZone: .gmt, dayFirst: false) == nil else { return false }
        let lower = text.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.isDisjoint(with: header.union(payment)) && !lower.contains("receipt")
    }
}

/// Date patterns found on receipts (milestone 3 §17.2 "date proposals").
nonisolated enum ReceiptDateParser {
    nonisolated struct Match: Equatable, Sendable {
        let date: Date
        /// Day and month could be swapped (both ≤ 12) or the year was two digits.
        let isAmbiguous: Bool
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func date(in text: String, timeZone: TimeZone, dayFirst: Bool) -> Match? {
        let lower = text.lowercased()
        if let match = lower.firstMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
           let date = make(Int(match.1), Int(match.2), Int(match.3), timeZone) {
            return Match(date: date, isAmbiguous: false)
        }
        if let match = lower.firstMatch(of: /\b(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{2,4})\b/),
           let first = Int(match.1), let second = Int(match.2), var year = Int(match.3) {
            let twoDigitYear = match.3.count == 2
            if twoDigitYear { year += 2000 }
            var (month, day) = dayFirst ? (second, first) : (first, second)
            if month > 12, day <= 12 { swap(&month, &day) }
            let ambiguous = (first <= 12 && second <= 12 && first != second) || twoDigitYear
            if let date = make(year, month, day, timeZone) { return Match(date: date, isAmbiguous: ambiguous) }
        }
        if let match = lower.firstMatch(of: /\b([a-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b/),
           let month = months.firstIndex(of: String(match.1)), let date = make(Int(match.3), month + 1, Int(match.2), timeZone) {
            return Match(date: date, isAmbiguous: false)
        }
        if let match = lower.firstMatch(of: /\b(\d{1,2})\s+([a-z]{3})[a-z]*\.?,?\s+(\d{4})\b/),
           let month = months.firstIndex(of: String(match.2)), let date = make(Int(match.3), month + 1, Int(match.1), timeZone) {
            return Match(date: date, isAmbiguous: false)
        }
        return nil
    }

    private static func make(_ year: Int?, _ month: Int?, _ day: Int?, _ timeZone: TimeZone) -> Date? {
        guard let year, let month, let day, (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
