import Foundation

/// The only gate through which Square Up opens or stores an external payment link.
///
/// Rules (milestone 2 §16):
/// - HTTPS only. `javascript:`, `data:`, `file:`, `http:`, and every custom scheme are rejected.
/// - The host must be on the provider's allowlist (exact host, or a subdomain where noted).
/// - No embedded credentials and no non-default ports.
/// - Providers without a documented link format (Apple Cash, Venmo, cash, other) accept no links.
nonisolated enum ExternalURLPolicy {
    /// Allowlisted hosts. A leading "." means the domain and any of its subdomains.
    static func allowedHosts(for provider: PaymentProviderKind) -> [String] {
        switch provider {
        case .paypal: ["paypal.me", "www.paypal.me", "paypal.com", "www.paypal.com"]
        case .cashApp: ["cash.app"]
        // Zelle moved from zellepay.com to zelle.com; QR links may use either, with subdomains.
        case .zelle: [".zelle.com", ".zellepay.com"]
        case .appleCash, .venmo, .cash, .other: []
        }
    }

    static func isAllowed(_ url: URL, for provider: PaymentProviderKind) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), !host.isEmpty
        else { return false }
        return allowedHosts(for: provider).contains { allowed in
            if allowed.hasPrefix(".") {
                let root = String(allowed.dropFirst())
                return host == root || host.hasSuffix(allowed)
            }
            return host == allowed
        }
    }

    /// Parses user input into an allowlisted HTTPS URL. A bare host ("cash.app/$maya") is
    /// treated as HTTPS; any explicit scheme other than `https` is rejected.
    static func url(from text: String, for provider: PaymentProviderKind) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if let schemeEnd = trimmed.range(of: "://") {
            guard trimmed[..<schemeEnd.lowerBound].lowercased() == "https" else { return nil }
            candidate = trimmed
        } else if trimmed.contains(":") {
            // "javascript:alert(1)", "data:...", "venmo:..." — any other scheme form.
            return nil
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate), isAllowed(url, for: provider) else { return nil }
        return url
    }
}
