import Foundation

/// Name presentation rules shared by every screen that shows a person.
///
/// Rule from the design guide: never distinguish two people by initials alone. When a short
/// name is ambiguous inside a set of people, the label grows until it is unique.
nonisolated enum PersonIdentity {
    /// Up to two initials, using the system's name parsing (handles "Priya Natarajan",
    /// "María José García", single names, and non-Latin scripts).
    static func initials(for displayName: String) -> String {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .abbreviated
        if let components = formatter.personNameComponents(from: displayName) {
            let abbreviated = formatter.string(from: components)
            if !abbreviated.isEmpty { return String(abbreviated.prefix(2)).uppercased() }
        }
        let words = displayName.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    static func firstName(for displayName: String) -> String {
        displayName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? displayName
    }

    /// Short labels for a set of people, disambiguated within that set.
    ///
    /// - "Maya Chen", "Alex Morgan" → "Maya", "Alex"
    /// - "Alex Morgan", "Alex Rivera" → "Alex M.", "Alex R."
    /// - two "Alex Morgan"s → full name plus handle when available
    static func shortLabels(for members: [Member]) -> [MemberID: String] {
        var labels: [MemberID: String] = [:]
        let byFirst = Dictionary(grouping: members) { firstName(for: $0.displayName).lowercased() }
        for (_, group) in byFirst {
            if group.count == 1, let only = group.first {
                labels[only.id] = firstName(for: only.displayName)
                continue
            }
            let withInitial = group.map { member -> (Member, String) in
                let parts = member.displayName.split(whereSeparator: \.isWhitespace)
                let first = parts.first.map(String.init) ?? member.displayName
                if let last = parts.dropFirst().last, let initial = last.first {
                    return (member, "\(first) \(initial).")
                }
                return (member, member.displayName)
            }
            let counts = Dictionary(grouping: withInitial, by: { $0.1.lowercased() }).mapValues(\.count)
            for (member, label) in withInitial {
                if counts[label.lowercased()] == 1 {
                    labels[member.id] = label
                } else if let handle = member.handle, !handle.isEmpty {
                    labels[member.id] = "\(member.displayName) (@\(handle))"
                } else {
                    labels[member.id] = member.displayName
                }
            }
        }
        return labels
    }

    /// "you", "Maya", "Maya and Alex", "Maya, Alex, and 3 others" — for sentences and
    /// accessibility labels. Uses the system list formatter for localisation.
    static func list(
        _ members: [Member],
        currentUserID: MemberID?,
        maximumNames: Int = 3
    ) -> String {
        let labels = shortLabels(for: members)
        var names: [String] = []
        var others = 0
        let ordered = members.sorted { lhs, rhs in
            (lhs.id == currentUserID ? 0 : 1) < (rhs.id == currentUserID ? 0 : 1)
        }
        for member in ordered {
            if names.count < maximumNames {
                names.append(member.id == currentUserID
                    ? String(localized: "you", comment: "Refers to the current user inside a list of people")
                    : labels[member.id] ?? member.displayName)
            } else {
                others += 1
            }
        }
        if others > 0 {
            names.append(Inflect.string("^[\(others) other](inflect: true)"))
        }
        return names.formatted(.list(type: .and))
    }
}
