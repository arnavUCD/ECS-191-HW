import Foundation

// Shared by the full app and the App Clip (this file is compiled into both targets), so both read
// exactly the same invitations: `https://<server>/r/<token>` (the App Clip / universal-link URL and
// what the QR code holds), `squp://join/<token>` (the full app's own scheme, offered by the `/r/`
// page), a bare token, or the room's short code typed by hand (`ABCD-EFGH-JKMN`).

/// Invitation links. The token is 256 random bits (43 URL-safe Base64 characters).
nonisolated enum InvitationLink {
    /// The full app's URL scheme.
    static let appScheme = "squp"

    /// 256-bit tokens are 43 URL-safe Base64 characters; accept a little slack, nothing else.
    static func isWellFormed(_ token: String) -> Bool {
        (32...128).contains(token.count) && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func token(fromPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "r" else { return nil }
        let token = String(parts[1])
        return isWellFormed(token) ? token : nil
    }

    /// The token in an invitation URL: `squp://join/<token>`, or `https://<expected host>/r/<token>`.
    /// A link to any other host is never accepted (it isn't this server's invitation).
    static func token(from url: URL, expectedHost: String?, expectedPort: Int? = nil) -> String? {
        let scheme = url.scheme?.lowercased()
        if scheme == appScheme, url.host()?.lowercased() == "join" {
            let token = url.pathComponents.first { $0 != "/" } ?? ""
            return isWellFormed(token) ? token : nil
        }
        guard scheme == "https" || scheme == "http", let expectedHost, url.host()?.lowercased() == expectedHost.lowercased(),
              url.port == expectedPort else { return nil }
        return token(fromPath: url.path())
    }

    static func appURL(token: String) -> URL {
        var components = URLComponents()
        components.scheme = appScheme
        components.host = "join"
        components.path = "/\(token)"
        return components.url!
    }
}

/// A temporary room's short code: 12 Crockford Base32 characters (60 bits), shown as
/// `ABCD-EFGH-JKMN`. Read the same way as the server: any case, spaces and dashes ignored, and the
/// usual misreadings fixed (O → 0, I/L → 1). Letters I, L, O, U never appear in a code.
nonisolated enum RoomCode {
    static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    static let length = 12

    static func normalize(_ text: String) -> String? {
        guard text.count <= 64 else { return nil }
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1")
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }

    /// Grouped in fours for reading aloud.
    static func display(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: min(4, code.count - start))
            return String(code[from..<to])
        }.joined(separator: "-")
    }
}

/// Whatever someone opened, pasted, scanned, or typed to join a room.
nonisolated enum InvitationInput: Hashable, Sendable {
    case token(String)
    case code(String)

    static func parse(_ text: String, expectedHost: String?, expectedPort: Int? = nil) -> InvitationInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return InvitationLink.token(from: url, expectedHost: expectedHost, expectedPort: expectedPort).map(InvitationInput.token)
        }
        if let code = RoomCode.normalize(trimmed) { return .code(code) }
        return InvitationLink.isWellFormed(trimmed) ? .token(trimmed) : nil
    }
}
