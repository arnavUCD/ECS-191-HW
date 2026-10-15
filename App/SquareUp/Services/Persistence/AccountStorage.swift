import CryptoKit
import Foundation
import OSLog
import SwiftData

/// A signed-in account's private local namespace: a one-way hash of the immutable Firebase UID.
/// Directory names, preference suites, and Keychain services use it; the UID itself (and never
/// the email address) appears in no file name and no log.
nonisolated struct AccountNamespace: Hashable, Codable, Sendable, CustomStringConvertible {
    let id: String

    init(uid: String) {
        let digest = SHA256.hash(data: Data("squareup.account.v1:\(uid)".utf8))
        id = String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    init(id: String) {
        self.id = id
    }

    var description: String { "account-\(id.prefix(8))" }
}

/// Where each account's local data lives (milestone 7 hardening):
///
/// ```
/// Application Support/
///   Accounts/<namespace>/Ledger.store     this account's local groups, expenses, payments, rooms
///   Accounts/<namespace>/Receipts/        its receipt images
///   Accounts/<namespace>/SharedRooms.json its receipt-room directory
///   Accounts/legacy-claim.json            which namespace owns the pre-account data (if any)
///   SharedGroups/<hash>/…                 shared-group caches (already per account)
///   SquareUp.store, Receipts/, SharedRooms.json   data from earlier builds ("legacy")
/// ```
nonisolated struct AccountStorageLayout: Sendable {
    let root: URL
    /// The store earlier builds opened (SwiftData's default location for `SquareUp`).
    let legacyLedgerURL: URL

    init(root: URL, legacyLedgerURL: URL? = nil) {
        self.root = root
        self.legacyLedgerURL = legacyLedgerURL ?? root.appending(path: "\(ModelContainerFactory.storeName).store")
    }

    static var standard: AccountStorageLayout {
        AccountStorageLayout(root: .applicationSupportDirectory, legacyLedgerURL: ModelConfiguration(ModelContainerFactory.storeName).url)
    }

    var accountsDirectory: URL { root.appending(path: "Accounts", directoryHint: .isDirectory) }
    var claimURL: URL { accountsDirectory.appending(path: "legacy-claim.json") }

    func directory(for namespace: AccountNamespace) -> URL {
        accountsDirectory.appending(path: namespace.id, directoryHint: .isDirectory)
    }

    func ledgerURL(for namespace: AccountNamespace) -> URL { directory(for: namespace).appending(path: "Ledger.store") }
    func receiptsDirectory(for namespace: AccountNamespace) -> URL { directory(for: namespace).appending(path: "Receipts", directoryHint: .isDirectory) }
    func roomDirectoryURL(for namespace: AccountNamespace) -> URL { directory(for: namespace).appending(path: "SharedRooms.json") }
    var sharedGroupCacheRoot: URL { root.appending(path: "SharedGroups", directoryHint: .isDirectory) }

    // Earlier builds kept one unscoped copy of everything.
    var legacyReceiptsDirectory: URL { root.appending(path: "Receipts", directoryHint: .isDirectory) }
    var legacyRoomDirectoryURL: URL { root.appending(path: "SharedRooms.json") }

    /// Creates the account's directory: complete-unless-open protection, excluded from backup
    /// (shared data comes back from the server; local-only data follows the device backup policy
    /// of the app container, which still includes the store itself).
    func prepareDirectory(for namespace: AccountNamespace) throws {
        let directory = directory(for: namespace)
        guard !FileManager.default.fileExists(atPath: directory.path()) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
    }

    /// The preference suite for one account (e.g. its AI-processing consent).
    static func defaultsSuiteName(for namespace: AccountNamespace) -> String { "\(Log.subsystem).account.\(namespace.id)" }

    /// The Keychain service for one account's own secrets (e.g. receipt-room invitation links).
    static func keychainService(for namespace: AccountNamespace) -> String { "\(Log.subsystem).credentials.\(namespace.id)" }
}

/// Who owns the data an earlier build kept without any account (milestone 7 hardening §1).
///
/// - At the first launch of this build, the account remembered on this iPhone (the person who was
///   using that data, including an anonymous account that later upgrades) becomes the *candidate*.
/// - When the candidate signs in, the data is bound to it — once, durably, before it is opened.
/// - Anyone else is never given it silently: they see a clear choice with counts only, and only
///   when their own space is still empty. Declining is remembered per account.
/// - Nothing is moved, copied, or deleted: the files stay where they were; the claim record says
///   whose they are. Writing the record is the only step, so an interruption leaves it unclaimed and
///   the next attempt simply tries again.
nonisolated struct LegacyClaim: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// No data from an earlier build.
        case none
        /// Data exists and belongs to no account yet.
        case pending
        /// Bound to `owner`.
        case claimed
    }

    var state: State
    var candidate: AccountNamespace?
    var owner: AccountNamespace?
    var declinedBy: Set<AccountNamespace> = []
    var updatedAt: Date
}

/// What a signed-in account should do about earlier data.
nonisolated enum LegacyResolution: Equatable, Sendable {
    /// This account owns it: open it as the account's ledger.
    case owned
    /// This account is the remembered candidate and its own space is empty: bind it now.
    case claimAutomatically
    /// Offer a choice (counts only).
    case offer
    /// Nothing to do.
    case unavailable
}

@MainActor
final class LegacyDataRegistry {
    nonisolated enum ClaimError: Error, Equatable {
        case ownedByAnotherAccount
        case nothingToClaim
        case writeFailed
    }

    let layout: AccountStorageLayout
    private(set) var claim: LegacyClaim
    private let write: (Data, URL) throws -> Void
    private let now: () -> Date

    init(layout: AccountStorageLayout, write: @escaping (Data, URL) throws -> Void = LegacyDataRegistry.atomicWrite, now: @escaping () -> Date = { .now }) {
        self.layout = layout
        self.write = write
        self.now = now
        claim = (try? Data(contentsOf: layout.claimURL)).flatMap { try? JSONDecoder().decode(LegacyClaim.self, from: $0) }
            ?? LegacyClaim(state: .none, updatedAt: now())
    }

    /// Whether the claim record has been written before (first launch of this build otherwise).
    var isRecorded: Bool { FileManager.default.fileExists(atPath: layout.claimURL.path()) }

    /// First launch of this build: records whether earlier data exists and who was using it.
    /// Never changes an existing record.
    func inspect(rememberedUID: String?, legacyHasData: () -> Bool) {
        guard !isRecorded else { return }
        let hasData = legacyHasData()
        claim = LegacyClaim(state: hasData ? .pending : .none, candidate: hasData ? rememberedUID.map(AccountNamespace.init(uid:)) : nil,
                            updatedAt: now())
        try? persist()
        Log.persistence.info("Earlier data on this iPhone: \(hasData ? "present" : "none", privacy: .public)")
    }

    func resolution(for namespace: AccountNamespace, ownSpaceIsEmpty: Bool) -> LegacyResolution {
        switch claim.state {
        case .none:
            return .unavailable
        case .claimed:
            return claim.owner == namespace ? .owned : .unavailable
        case .pending:
            if claim.candidate == namespace, ownSpaceIsEmpty { return .claimAutomatically }
            if claim.declinedBy.contains(namespace) || !ownSpaceIsEmpty { return .unavailable }
            return .offer
        }
    }

    /// Binds the earlier data to `namespace` (idempotent for the same account).
    func claim(for namespace: AccountNamespace) throws(ClaimError) {
        switch claim.state {
        case .claimed:
            guard claim.owner == namespace else { throw .ownedByAnotherAccount }
            return
        case .none:
            throw .nothingToClaim
        case .pending:
            var next = claim
            next.state = .claimed
            next.owner = namespace
            next.updatedAt = now()
            do {
                try persist(next)
            } catch {
                throw .writeFailed
            }
            claim = next
            Log.persistence.info("Earlier data on this iPhone is now bound to one account")
        }
    }

    /// "Not mine": this account isn't asked again; the data stays aside for its owner.
    func decline(for namespace: AccountNamespace) {
        guard claim.state == .pending else { return }
        claim.declinedBy.insert(namespace)
        claim.updatedAt = now()
        try? persist()
    }

    private func persist(_ value: LegacyClaim? = nil) throws {
        try FileManager.default.createDirectory(at: layout.accountsDirectory, withIntermediateDirectories: true)
        try write(try JSONEncoder().encode(value ?? claim), layout.claimURL)
    }

    nonisolated static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// Deleting the app removes its UserDefaults and Application Support, but not its Keychain items.
/// On the first launch of a fresh install (no install marker and no local data), sign-ins and
/// secrets an earlier install left behind are cleared, so the app opens at Welcome with nothing of
/// any earlier account. An existing install (it has local data) only gets the marker.
nonisolated enum FreshInstall {
    static let markerKey = "squareup.install.marker"

    /// Returns `true` when leftovers were cleared.
    @discardableResult
    static func clearLeftovers(defaults: UserDefaults, hasLocalData: Bool, clearKeychain: () -> Void) -> Bool {
        defer { defaults.set(true, forKey: markerKey) }
        guard !defaults.bool(forKey: markerKey), !hasLocalData else { return false }
        clearKeychain()
        return true
    }

    static func hasLocalData(_ layout: AccountStorageLayout, fileManager: FileManager = .default) -> Bool {
        [layout.accountsDirectory, layout.legacyLedgerURL, layout.sharedGroupCacheRoot].contains { fileManager.fileExists(atPath: $0.path()) }
    }
}
