import CryptoKit
import Foundation
import OSLog
import Synchronization

/// The last confirmed state of each shared group, kept per account so groups stay readable
/// offline and across relaunches (milestone 7 §7.2).
///
/// - Namespaced by a hash of the Firebase account ID: two accounts on one iPhone never share or
///   see each other's files. Signing out deletes the account's directory (`purge`).
/// - Holds only what the server confirmed (`GroupSnapshotDTO`, exactly as sent), plus this
///   person's changes that couldn't be sent yet and receipt drafts started on this iPhone.
///   Nothing here is ever treated as authoritative.
/// - Files use complete-unless-open data protection and are excluded from backups (everything
///   can be fetched again from the server).
/// - `root == nil` keeps everything in memory (tests and previews).
final nonisolated class SharedGroupCache: Sendable {
    nonisolated struct UnsentChange: Codable, Hashable, Sendable, Identifiable {
        var id: String { envelope.idempotencyKey }
        /// Resent byte-for-byte (same command ID and idempotency key), so it applies at most once.
        let envelope: GroupCommandEnvelope
        /// A short description for "Waiting for connection" ("Add Groceries · $42.00").
        let summary: String
        let queuedAt: Date
        /// Set when the server refused it after reconnecting; it then waits for a decision.
        var refusal: String?
    }

    nonisolated struct GroupEntry: Codable, Sendable {
        var snapshot: GroupSnapshotDTO
        var cachedAt: Date
        var unsent: [UnsentChange] = []
        /// Receipt drafts and rooms started on this iPhone for this group (local until saved).
        var rooms: [ReceiptRoom] = []
    }

    nonisolated struct AccountEntry: Codable, Sendable {
        var profile: ProfileDTO?
        var groups: [GroupSummaryDTO] = []
        var updatedAt: Date?
        /// Local group ID → the stable publication ID reused on every retry (§8.3).
        var publications: [String: String] = [:]
    }

    let root: URL?
    private let memory = Mutex<[String: Data]>([:])

    init(root: URL?) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "SharedGroups", directoryHint: .isDirectory)
    }

    static func accountKey(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: - Groups

    func group(_ groupID: GroupID, account: String) -> GroupEntry? {
        read(path(account, "group-\(SharedGroupMapper.id(groupID)).json"))
    }

    func save(_ entry: GroupEntry, group groupID: GroupID, account: String) {
        write(entry, path(account, "group-\(SharedGroupMapper.id(groupID)).json"))
    }

    func removeGroup(_ groupID: GroupID, account: String) {
        delete(path(account, "group-\(SharedGroupMapper.id(groupID)).json"))
    }

    func cachedGroupIDs(account: String) -> [GroupID] {
        let prefix = "\(Self.accountKey(account))/group-"
        let names: [String]
        if let root {
            let directory = root.appending(path: Self.accountKey(account), directoryHint: .isDirectory)
            names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []).map { "\(Self.accountKey(account))/\($0)" }
        } else {
            names = memory.withLock { Array($0.keys) }
        }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .compactMap { GroupID(string: String($0.dropFirst(prefix.count).dropLast(5))) }
    }

    // MARK: - Account

    func account(_ account: String) -> AccountEntry? {
        read(path(account, "account.json"))
    }

    func save(_ entry: AccountEntry, account: String) {
        write(entry, path(account, "account.json"))
    }

    /// Removes everything this account cached on this iPhone (sign-out, §13.1).
    func purge(account: String) {
        let key = Self.accountKey(account)
        if let root {
            try? FileManager.default.removeItem(at: root.appending(path: key, directoryHint: .isDirectory))
        } else {
            memory.withLock { storage in storage = storage.filter { !$0.key.hasPrefix("\(key)/") } }
        }
        Log.sync.info("Removed this account's cached shared groups from the device")
    }

    func hasData(account: String) -> Bool {
        let key = Self.accountKey(account)
        if let root { return FileManager.default.fileExists(atPath: root.appending(path: key).path()) }
        return memory.withLock { $0.keys.contains { $0.hasPrefix("\(key)/") } }
    }

    // MARK: - Storage

    private func path(_ account: String, _ name: String) -> String {
        "\(Self.accountKey(account))/\(name)"
    }

    private func read<T: Decodable>(_ path: String) -> T? {
        let data: Data?
        if let root {
            data = try? Data(contentsOf: root.appending(path: path))
        } else {
            data = memory.withLock { $0[path] }
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // An unreadable cache is discarded, never half-used; the server has the truth.
            Log.sync.error("Discarded an unreadable shared-group cache file")
            delete(path)
            return nil
        }
    }

    private func write(_ value: some Encodable, _ path: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard let root else {
            memory.withLock { $0[path] = data }
            return
        }
        let url = root.appending(path: path)
        do {
            var directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path()) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            Log.sync.error("Couldn't save a shared group for offline reading (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    private func delete(_ path: String) {
        if let root {
            try? FileManager.default.removeItem(at: root.appending(path: path))
        } else {
            _ = memory.withLock { $0.removeValue(forKey: path) }
        }
    }
}
