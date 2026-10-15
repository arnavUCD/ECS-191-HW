import Foundation

nonisolated enum Inflect {
    /// A localized string with automatic grammar agreement, e.g.
    /// `Inflect.string("Across ^[\(count) group](inflect: true)")` → "Across 1 group" / "Across 4 groups".
    static func string(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }
}
