import Foundation

nonisolated enum RelativeTime {
    /// "2 days ago", "yesterday" — relative to an explicit `now`, so fixed-clock previews, tests,
    /// and UI tests read correctly (the system relative style always uses the real clock).
    static func string(for date: Date, relativeTo now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
