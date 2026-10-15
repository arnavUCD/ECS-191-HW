import Foundation
import Observation
import OSLog

/// The shared rooms this device hosts or joined (milestone 4 §4.3), so they can be reopened
/// after relaunch. Holds no secrets: credentials live in the Keychain and the room itself on
/// the server. Stored as a small JSON file next to the ledger.
@Observable
final class SharedRoomDirectory {
    nonisolated struct Record: Codable, Hashable, Sendable, Identifiable {
        nonisolated enum Role: String, Codable, Sendable {
            case host
            case participant
        }

        let roomID: ReceiptRoomID
        var role: Role
        var title: String
        var state: ReceiptRoomState
        var revision: Int
        var updatedAt: Date
        /// Host: the group the expense will be saved to.
        var groupID: GroupID?
        /// Host: who each guest is in the group (participant ID → group member).
        var guestLinks: [String: MemberID] = [:]
        /// Host: the terminal state already mirrored onto the local room.
        var adoptedState: ReceiptRoomState?
        /// Host: why mirroring the final state failed, if it did (shown with a retry).
        var adoptionProblem: RemoteIssue.Kind?
        /// `temporary` for "Split with people now" rooms (no group; settled inside the room).
        var kind: String?
        /// Temporary rooms: when the room ended (square, cancelled, or expired).
        var endedAt: Date?

        var id: ReceiptRoomID { roomID }
        var isTemporary: Bool { kind == "temporary" }
        /// A temporary room keeps going after finalization (people pay and the payer confirms).
        var isFinished: Bool { isTemporary ? endedAt != nil : state.isTerminal }
    }

    private(set) var records: [Record] = []
    @ObservationIgnored private let fileURL: URL?

    /// `fileURL == nil` keeps everything in memory (tests, previews, UI testing).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "SharedRooms.json", directoryHint: .notDirectory)
    }

    func record(_ id: ReceiptRoomID) -> Record? { records.first { $0.roomID == id } }

    /// Newest first: unfinished rooms, then finished ones.
    var sorted: [Record] {
        records.sorted { ($0.isFinished ? 1 : 0, -$0.updatedAt.timeIntervalSince1970) < ($1.isFinished ? 1 : 0, -$1.updatedAt.timeIntervalSince1970) }
    }

    func upsert(_ id: ReceiptRoomID, _ update: (inout Record) -> Void, creating make: () -> Record) {
        if let index = records.firstIndex(where: { $0.roomID == id }) {
            var record = records[index]
            update(&record)
            guard record != records[index] else { return }
            records[index] = record
        } else {
            var record = make()
            update(&record)
            records.append(record)
        }
        save()
    }

    func update(_ id: ReceiptRoomID, _ update: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.roomID == id }) else { return }
        var record = records[index]
        update(&record)
        guard record != records[index] else { return }
        records[index] = record
        save()
    }

    func remove(_ id: ReceiptRoomID) {
        records.removeAll { $0.roomID == id }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            Log.sync.error("Couldn't save shared rooms: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

extension RemoteIssue {
    /// A persistable summary of an issue (no server text).
    nonisolated enum Kind: String, Codable, Sendable {
        case guestsNeedMatching
        case totalsDiffer
        case unavailable
    }
}
