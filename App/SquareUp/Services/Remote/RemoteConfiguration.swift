import Foundation

/// Where shared Receipt Rooms live (milestone 4). Read from Info.plist, which is filled from
/// `Config/Remote.xcconfig` — committed with the production client configuration (API host and
/// Firebase's public client identifiers; never a secret) — and the optional, gitignored
/// `Remote.local.xcconfig` override. Nothing environment-specific is compiled into the source.
nonisolated struct RemoteConfiguration: Sendable, Equatable {
    nonisolated enum AuthMode: String, Sendable {
        /// Firebase Authentication ID tokens, verified by the server.
        case firebase
        /// `Authorization: Dev <install id>` for a local server with development auth enabled.
        /// DEBUG builds only.
        case development
    }

    /// The API origin, e.g. `https://example.appspot.com`.
    let baseURL: URL
    let authMode: AuthMode
    let firebaseAPIKey: String?

    /// `nil` when this build has no server configured (sharing then explains it isn't set up).
    static func fromBundle(_ info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> RemoteConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
            return raw
        }
        return make(scheme: value("SquareUpAPIScheme"), host: value("SquareUpAPIHost"),
                    authMode: value("SquareUpAuthMode"), firebaseAPIKey: value("SquareUpFirebaseAPIKey"))
    }

    static func make(scheme: String?, host: String?, authMode: String?, firebaseAPIKey: String?) -> RemoteConfiguration? {
        guard let host, let url = URL(string: "\(scheme ?? "https")://\(host)"), let scheme = url.scheme?.lowercased(),
              url.host() != nil, url.path().isEmpty || url.path() == "/" else { return nil }
        var mode = AuthMode(rawValue: authMode ?? "firebase") ?? .firebase
        #if !DEBUG
        mode = .firebase
        #endif
        // Plain HTTP is only for a development server on the local network.
        if scheme == "http", mode != .development { return nil }
        if scheme != "https", scheme != "http" { return nil }
        if mode == .firebase, firebaseAPIKey == nil { return nil }
        return RemoteConfiguration(baseURL: url, authMode: mode, firebaseAPIKey: firebaseAPIKey)
    }

    /// Whether an https link is an invitation to this server's rooms (`/r/<token>`).
    func invitationToken(in url: URL) -> String? {
        guard url.host()?.lowercased() == baseURL.host()?.lowercased(), url.port == baseURL.port else { return nil }
        return InvitationLink.token(fromPath: url.path())
    }
}

extension InvitationLink {
    /// Any invitation link the full app understands, from any source (scan, paste, open URL).
    nonisolated static func token(from url: URL, configuration: RemoteConfiguration?) -> String? {
        token(from: url, expectedHost: configuration?.baseURL.host(), expectedPort: configuration?.baseURL.port)
    }

    /// Text someone pasted: a full link or just the token.
    nonisolated static func token(fromText text: String, configuration: RemoteConfiguration?) -> String? {
        if case .token(let token)? = InvitationInput.parse(text, expectedHost: configuration?.baseURL.host(),
                                                           expectedPort: configuration?.baseURL.port) {
            return token
        }
        return nil
    }
}
