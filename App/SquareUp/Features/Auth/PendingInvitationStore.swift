import Foundation

/// An invitation opened before the person finished signing in.
nonisolated enum PendingInvitation: Codable, Equatable, Sendable {
    /// A shared group (`squp://join-group/<code>` or the `/g/<code>` page).
    case group(code: String)
    /// A Live Receipt Room (`squp://join/<token>` or the `/r/<token>` page).
    case room(token: String)
}

/// Keeps one pending invitation through sign-in, sign-up, email verification, and profile setup —
/// even across a relaunch — and hands it to the app once it's ready. Invitation codes and tokens
/// are secrets, so they live in the Keychain (this device only), never in logs or defaults.
nonisolated struct PendingInvitationStore: Sendable {
    private let keychain: KeychainStore?
    private static let key = "auth.pending-invitation"

    /// `keychain == nil` keeps nothing between launches (tests and previews).
    init(keychain: KeychainStore?) {
        self.keychain = keychain
    }

    func load() -> PendingInvitation? {
        keychain?.data(for: Self.key).flatMap { try? JSONDecoder().decode(PendingInvitation.self, from: $0) }
    }

    func save(_ invitation: PendingInvitation) {
        guard let keychain, let data = try? JSONEncoder().encode(invitation) else { return }
        _ = keychain.set(data, for: Self.key)
    }

    func clear() {
        _ = keychain?.remove(Self.key)
    }
}
