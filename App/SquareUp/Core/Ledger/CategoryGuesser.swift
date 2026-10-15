import Foundation

/// Deterministic category suggestion from an expense description. A suggestion only — the
/// person can always change it, and an explicit choice is never overwritten.
nonisolated enum CategoryGuesser {
    private static let keywords: [(ExpenseCategory, [String])] = [
        (.groceries, ["grocer*", "costco", "trader joe", "safeway", "whole foods", "market", "target", "supermarket"]),
        (.food, ["dinner", "lunch", "breakfast", "brunch", "pizza", "coffee", "cafe", "restaurant", "drinks", "bar", "tacos", "sushi", "catering", "boba", "food"]),
        (.housing, ["rent", "lease", "deposit", "furniture", "cleaning", "apartment"]),
        (.utilities, ["utilit*", "electric", "pg&e", "power", "water", "gas bill", "wifi", "wi-fi", "internet", "phone bill", "trash"]),
        (.transport, ["uber", "lyft", "taxi", "gas", "fuel", "parking", "train", "bart", "bus", "toll"]),
        (.travel, ["flight", "hotel", "airbnb", "cabin", "hostel", "trip", "rental car", "lodging"]),
        (.entertainment, ["movie*", "concert*", "ticket*", "show", "museum", "game*", "bowling", "karaoke", "lift*"]),
        (.supplies, ["supplies", "printing", "poster", "paper", "tape", "materials", "decor", "props", "easel"]),
    ]

    /// Keywords match whole words ("bar" does not match "BART"); a trailing `*` matches a word
    /// prefix ("grocer*" matches "groceries").
    static func guess(_ description: String) -> ExpenseCategory {
        let text = description.lowercased()
        guard !text.isEmpty else { return .other }
        for (category, words) in keywords where words.contains(where: { matches($0, in: text) }) {
            return category
        }
        return .other
    }

    private static func matches(_ keyword: String, in text: String) -> Bool {
        let isPrefix = keyword.hasSuffix("*")
        let word = NSRegularExpression.escapedPattern(for: isPrefix ? String(keyword.dropLast()) : keyword)
        let pattern = isPrefix ? "(?<![a-z])\(word)" : "(?<![a-z])\(word)(?![a-z])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
