import Foundation

/// How much of a destination to show (milestone 2 §10 "Display and privacy").
nonisolated enum DestinationDisclosure: Sendable {
    /// General profile and group views.
    case masked
    /// Only for a payer with an active obligation to this recipient, or the owner themself.
    case revealed
}

/// Turns destinations into display and VoiceOver text without ever logging them.
nonisolated enum DestinationPresentation {
    static func text(for value: DestinationValue, provider: PaymentProviderKind, disclosure: DestinationDisclosure) -> String {
        switch disclosure {
        case .revealed: revealed(value, provider: provider)
        case .masked: masked(value, provider: provider)
        }
    }

    static func revealed(_ value: DestinationValue, provider: PaymentProviderKind) -> String {
        switch value {
        case .phone(let phone): formatUSPhone(phone)
        case .email(let email): email
        case .username(let name):
            switch provider {
            case .paypal: "paypal.me/\(name)"
            case .cashApp: "$\(name)"
            default: "@\(name)"
            }
        case .link(let url): displayLink(url)
        case .instructions(let text): text
        }
    }

    static func masked(_ value: DestinationValue, provider: PaymentProviderKind) -> String {
        let dot = "\u{2022}"
        switch value {
        case .phone(let phone):
            return "\(dot)\(dot)\(dot)-\(dot)\(dot)\(dot)-" + String(phone.suffix(4))
        case .email(let email):
            let parts = email.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, let first = parts[0].first else { return "\(dot)\(dot)\(dot)" }
            return "\(first)\(dot)\(dot)\(dot)@\(parts[1])"
        case .username(let name):
            let sigil = provider == .cashApp ? "$" : (provider == .paypal ? "paypal.me/" : "@")
            guard let first = name.first else { return sigil }
            return name.count <= 2 ? "\(sigil)\(first)\(dot)" : "\(sigil)\(first)\(dot)\(dot)\(dot)\(name.last.map(String.init) ?? "")"
        case .link(let url):
            return "\(url.host() ?? "")/\(dot)\(dot)\(dot)"
        case .instructions(let text):
            // Instructions are written to be shown ("Cash in person"); still keep them short.
            return text.count > 40 ? String(text.prefix(39)) + "…" : text
        }
    }

    /// VoiceOver phrasing for masked values: distinguishable without reading the identifier.
    static func spokenMasked(_ value: DestinationValue, provider: PaymentProviderKind) -> String {
        switch value {
        case .phone(let phone):
            String(localized: "phone number ending in \(phone.suffix(4).map(String.init).joined(separator: " "))")
        case .email(let email):
            String(localized: "email at \(email.split(separator: "@").last.map(String.init) ?? "")")
        case .username(let name):
            String(localized: "username starting with \(name.first.map(String.init) ?? "")")
        case .link(let url):
            String(localized: "link on \(url.host() ?? "")")
        case .instructions(let text):
            text
        }
    }

    static func formatUSPhone(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        let national = digits.count == 11 ? String(digits.dropFirst()) : digits
        guard national.count == 10 else { return e164 }
        let area = national.prefix(3), exchange = national.dropFirst(3).prefix(3), line = national.suffix(4)
        return "(\(area)) \(exchange)-\(line)"
    }

    static func displayLink(_ url: URL) -> String {
        let host = url.host() ?? ""
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// Diagnostics never contain payment identifiers (milestone 2 §16): any `print`, `dump`,
/// string interpolation, or crash-report description of a destination shows only its kind.
nonisolated extension DestinationValue: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .phone: "phone(<redacted>)"
        case .email: "email(<redacted>)"
        case .username: "username(<redacted>)"
        case .link: "link(<redacted>)"
        case .instructions: "instructions(<redacted>)"
        }
    }

    var debugDescription: String { description }
}

nonisolated extension PaymentDestination: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "PaymentDestination(\(provider.rawValue), \(value), link: \(link == nil ? "none" : "<redacted>"), preferred: \(isPreferred), enabled: \(isEnabled))"
    }

    var debugDescription: String { description }
}
