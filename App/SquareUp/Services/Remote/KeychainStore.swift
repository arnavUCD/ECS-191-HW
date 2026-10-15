import Foundation
import Security

/// Minimal generic-password Keychain storage for credentials (CLAUDE.md §15, milestone 4 §8).
///
/// Items are this-device-only and available after first unlock, so polling can refresh a token
/// while the screen is locked but credentials never migrate to another device through backups.
nonisolated struct KeychainStore: Sendable {
    let service: String

    init(service: String = "\(Log.subsystem).credentials") {
        self.service = service
    }

    func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func set(_ data: Data?, for account: String) -> Bool {
        guard let data else { return remove(account) }
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func set(_ string: String?, for account: String) -> Bool {
        set(string.map { Data($0.utf8) }, for: account)
    }

    @discardableResult
    func remove(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Removes every item in this store's service (one account's own secrets, e.g. a demo's).
    @discardableResult
    func removeAll() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Removes every generic-password item this app stored (all services). Keychain items outlive
    /// the app, so a fresh install clears what an earlier install left (`FreshInstall`).
    @discardableResult
    static func removeAllItems() -> Bool {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
