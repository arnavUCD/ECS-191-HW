import Foundation

nonisolated enum DestinationValidationError: Error, Equatable, Sendable {
    case missingValue
    case invalidPhone
    case invalidEmail
    case invalidPhoneOrEmail
    case invalidUsername
    case invalidLink
    case missingLabel
    case tooLong
}

/// Raw text a person typed when adding a payment method.
nonisolated struct DestinationInput: Equatable, Sendable {
    var provider: PaymentProviderKind
    /// Phone, email, username, PayPal.Me link, cashtag, or instructions — depending on provider.
    var primary: String
    /// Optional official link: Cash App payment link or Zelle QR link.
    var link: String = ""
    /// Required for "other", optional elsewhere.
    var label: String = ""
}

/// Normalises and validates payment destinations per provider (milestone 2 §10).
///
/// Square Up cannot verify enrolment with any provider, so validation is about shape and
/// safety only: never about whether the account exists.
nonisolated enum PaymentDestinationValidator {
    static let maximumInstructionLength = 140
    static let maximumLabelLength = 40

    nonisolated struct Normalized: Equatable, Sendable {
        let value: DestinationValue
        let link: URL?
        let label: String?
    }

    static func validate(_ input: DestinationInput) throws(DestinationValidationError) -> Normalized {
        let primary = input.primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkText = input.link.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= maximumLabelLength else { throw .tooLong }
        let optionalLabel = label.isEmpty ? nil : label

        switch input.provider {
        case .appleCash:
            guard !primary.isEmpty else { throw .missingValue }
            return Normalized(value: try contact(primary), link: nil, label: optionalLabel)

        case .paypal:
            guard !primary.isEmpty else { throw .missingValue }
            guard let username = payPalUsername(from: primary) else { throw .invalidUsername }
            return Normalized(value: .username(username), link: nil, label: optionalLabel)

        case .cashApp:
            let link = try optionalLink(linkText, provider: .cashApp, requiredPathPrefix: "/$")
            if primary.isEmpty {
                guard let link else { throw .missingValue }
                return Normalized(value: .link(link), link: nil, label: optionalLabel)
            }
            guard let cashtag = cashtag(from: primary) else { throw .invalidUsername }
            return Normalized(value: .username(cashtag), link: link, label: optionalLabel)

        case .zelle:
            guard !primary.isEmpty else { throw .missingValue }
            let value = try contact(primary)
            let link = try optionalLink(linkText, provider: .zelle, requiredPathPrefix: nil)
            return Normalized(value: value, link: link, label: optionalLabel)

        case .venmo:
            guard !primary.isEmpty else { throw .missingValue }
            guard let username = venmoUsername(from: primary) else { throw .invalidUsername }
            return Normalized(value: .username(username), link: nil, label: optionalLabel)

        case .cash:
            let text = primary.isEmpty ? String(localized: "Cash in person") : primary
            guard text.count <= maximumInstructionLength else { throw .tooLong }
            return Normalized(value: .instructions(text), link: nil, label: optionalLabel)

        case .other:
            guard let optionalLabel else { throw .missingLabel }
            guard !primary.isEmpty else { throw .missingValue }
            guard primary.count <= maximumInstructionLength else { throw .tooLong }
            return Normalized(value: .instructions(primary), link: nil, label: optionalLabel)
        }
    }

    // MARK: Contacts

    private static func contact(_ text: String) throws(DestinationValidationError) -> DestinationValue {
        if text.contains("@") {
            guard let email = normalizeEmail(text) else { throw .invalidEmail }
            return .email(email)
        }
        guard let phone = normalizeUSPhone(text) else {
            throw text.contains(where: \.isLetter) ? .invalidPhoneOrEmail : .invalidPhone
        }
        return .phone(phone)
    }

    /// US numbers only (Apple Cash and Zelle are US services): 10 digits, or 11 starting with 1.
    static func normalizeUSPhone(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789+-(). ")
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let digits = text.filter(\.isNumber)
        let national: Substring
        switch digits.count {
        case 10: national = Substring(digits)
        case 11 where digits.hasPrefix("1"): national = digits.dropFirst()
        default: return nil
        }
        // NANP: area code and exchange cannot start with 0 or 1.
        guard let area = national.first, let exchange = national.dropFirst(3).first,
              !"01".contains(area), !"01".contains(exchange) else { return nil }
        return "+1" + national
    }

    static func normalizeEmail(_ text: String) -> String? {
        let email = text.lowercased()
        guard email.count <= 254,
              email.wholeMatch(of: /[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}/) != nil
        else { return nil }
        return email
    }

    // MARK: Usernames

    /// Accepts "maya", "@maya", "paypal.me/maya", or an https PayPal.Me / paypal.com/paypalme URL.
    static func payPalUsername(from text: String) -> String? {
        var candidate = text
        if text.contains("/") {
            guard let url = ExternalURLPolicy.url(from: text, for: .paypal) else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            let host = url.host()?.lowercased() ?? ""
            if host.hasSuffix("paypal.me") {
                guard let first = parts.first else { return nil }
                candidate = first
            } else {
                guard parts.count >= 2, parts[0].lowercased() == "paypalme" else { return nil }
                candidate = parts[1]
            }
        }
        candidate = candidate.hasPrefix("@") ? String(candidate.dropFirst()) : candidate
        guard candidate.wholeMatch(of: /[A-Za-z0-9]{1,20}/) != nil else { return nil }
        return candidate
    }

    /// Cashtags: 1–20 letters or digits with at least one letter; stored without "$".
    static func cashtag(from text: String) -> String? {
        let candidate = text.hasPrefix("$") ? String(text.dropFirst()) : text
        guard candidate.wholeMatch(of: /[A-Za-z0-9]{1,20}/) != nil, candidate.contains(where: \.isLetter) else { return nil }
        return candidate
    }

    /// Venmo usernames: 5–30 letters, digits, hyphens, or underscores; stored without "@".
    static func venmoUsername(from text: String) -> String? {
        let candidate = text.hasPrefix("@") ? String(text.dropFirst()) : text
        guard candidate.wholeMatch(of: /[A-Za-z0-9_\-]{5,30}/) != nil else { return nil }
        return candidate
    }

    // MARK: Links

    private static func optionalLink(
        _ text: String, provider: PaymentProviderKind, requiredPathPrefix: String?
    ) throws(DestinationValidationError) -> URL? {
        guard !text.isEmpty else { return nil }
        guard let url = ExternalURLPolicy.url(from: text, for: provider) else { throw .invalidLink }
        if let requiredPathPrefix {
            guard url.path().hasPrefix(requiredPathPrefix), url.path().count > requiredPathPrefix.count else { throw .invalidLink }
        }
        return url
    }
}
