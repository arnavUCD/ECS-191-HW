import Foundation

/// Deterministic quick-entry parsing. Always available; the guaranteed fallback so the core
/// expense flow never depends on Apple Intelligence (CLAUDE.md §6.2).
///
/// Understands phrasings like:
/// - "I paid $80 for dinner and want to split it equally among Alex, Maya, Jordan, and me"
/// - "Maya paid 42.50 for groceries with me and Jordan"
/// - "Uber 18 split with Sam"
nonisolated struct RuleBasedQuickEntryProvider: QuickEntryProviding {
    let descriptor = AIProviderDescriptor(
        id: "rules.quick-entry", displayName: String(localized: "Built-in parser"), location: .rules, version: "1"
    )

    func availability() async -> AIAvailability { .available }

    func candidate(for text: String, context: QuickEntryContext) async throws -> QuickEntryCandidate {
        Self.parse(text)
    }

    static func parse(_ text: String) -> QuickEntryCandidate {
        let normalized = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        return QuickEntryCandidate(
            amountText: amount(in: normalized),
            description: description(in: normalized),
            payerName: payer(in: lower),
            participantNames: participants(in: normalized),
            splitsEqually: !(lower.contains("exact") || lower.contains("percent") || lower.contains("%"))
        )
    }

    private static func amount(in text: String) -> String? {
        // Prefer a number attached to a currency marker, then any standalone number.
        let marked = /(?:[$€£₹]\s?)(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?|(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?\s?(?:dollars|bucks|usd)/
            .ignoresCase()
        if let match = text.firstMatch(of: marked) {
            let integer = match.1 ?? match.3
            let fraction = match.2 ?? match.4
            return join(integer, fraction)
        }
        let plain = /(?:^|[^\w.])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?![\w%])/
        if let match = text.firstMatch(of: plain) {
            return join(match.1, match.2)
        }
        return nil
    }

    private static func join(_ integer: Substring?, _ fraction: Substring?) -> String? {
        guard let integer else { return nil }
        let digits = integer.replacingOccurrences(of: ",", with: "")
        if let fraction { return "\(digits).\(fraction)" }
        return digits
    }

    private static func payer(in lower: String) -> String? {
        if lower.range(of: #"\b(i|i've|i have)\s+(paid|covered|bought|got)\b"#, options: .regularExpression) != nil {
            return "me"
        }
        if let match = lower.firstMatch(of: /([a-z][a-z'\-]+(?:\s[a-z][a-z'\-]+)?)\s+(?:paid|covered|bought|got)\b/) {
            let name = String(match.1)
            let stop: Set = ["who", "they", "we", "it", "and", "split"]
            if !stop.contains(name) { return name }
        }
        return "me"
    }

    private static func description(in text: String) -> String? {
        let pattern = /(?i)\bfor\s+(?:the\s+|a\s+|an\s+|our\s+)?(.+?)(?=\s+(?:and|split|with|among|between|that|which)\b|[,.;!]|$)/
        if let match = text.firstMatch(of: pattern) {
            return capitalized(String(match.1))
        }
        // "Uber 18 split with Sam" → leading words before the amount.
        if let match = text.firstMatch(of: /^([A-Za-z][A-Za-z'&\- ]{1,40}?)\s+[$€£₹]?\d/) {
            let candidate = String(match.1).trimmingCharacters(in: .whitespaces)
            let lower = candidate.lowercased()
            if !lower.hasPrefix("i ") && !lower.contains(" paid") && lower != "i" {
                return capitalized(candidate)
            }
        }
        return nil
    }

    private static func participants(in text: String) -> [String] {
        let pattern = /(?i)\b(?:among|between|with)\s+(.+?)(?:[.;!]|$)/
        guard let match = text.firstMatch(of: pattern) else { return [] }
        var list = String(match.1)
        for filler in [" equally", " evenly", " each"] {
            list = list.replacingOccurrences(of: filler, with: "", options: .caseInsensitive)
        }
        return list
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: #"\s+and\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: #"^(?i)and\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    private static func capitalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}
