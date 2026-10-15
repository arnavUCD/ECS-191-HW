import Foundation
import OSLog

/// Structured, privacy-aware diagnostics.
///
/// Rules (see CLAUDE.md §15):
/// - Never log names, notes, receipt text, amounts, tokens, or free-form user input.
/// - Identifiers may be logged with `privacy: .private(mask: .hash)` so issues can be
///   correlated without revealing the value.
/// - Counts, durations, provider names, and error *types* are safe to log publicly.
nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "edu.ucdavis.ecs191.SquareUp"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let haptics = Logger(subsystem: subsystem, category: "haptics")
    static let intents = Logger(subsystem: subsystem, category: "intents")
    /// Provider names and outcomes only — never destinations, amounts, memos, or URLs.
    static let payments = Logger(subsystem: subsystem, category: "payments")
    /// Stage names, durations, counts, and provider kinds only — never receipt text, merchants,
    /// item names, amounts, or images (milestone 3 §14).
    static let receipts = Logger(subsystem: subsystem, category: "receipts")
    /// Milestone 4 shared rooms: request routes, status codes, error codes, revisions, and
    /// durations only — never tokens, credentials, names, items, amounts, or invitation URLs.
    static let sync = Logger(subsystem: subsystem, category: "sync")
}
