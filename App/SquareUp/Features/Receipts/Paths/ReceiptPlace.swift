import Foundation

/// Where a receipt draft on this iPhone went after review, so lists open the right thing: still a
/// draft, a temporary room it started, or a receipt posted to a shared group.
enum ReceiptPlace: Equatable {
    case draft
    case temporaryRoom(SharedRoomDirectory.Record)
    case groupReceipt(GroupID, name: String, GroupReceiptDTO)
}

extension AppEnvironment {
    func place(of id: ReceiptRoomID) -> ReceiptPlace {
        if let record = sharing.directory.record(id), record.isTemporary { return .temporaryRoom(record) }
        for groupID in sharedGroups.sharedGroupIDs {
            if let ledger = sharedGroups.ledger(for: groupID), let receipt = ledger.groupReceipt(id) {
                return .groupReceipt(groupID, name: ledger.groupName, receipt)
            }
        }
        return .draft
    }

    /// A draft still worth listing as "in progress" (not a temporary room or group receipt that ended).
    func isInProgress(_ id: ReceiptRoomID) -> Bool {
        switch place(of: id) {
        case .draft: true
        case .temporaryRoom(let record): !record.isFinished
        case .groupReceipt(_, _, let receipt): receipt.isPending
        }
    }

    /// What the row says about it, when it isn't a plain draft.
    func progressText(for id: ReceiptRoomID) -> String? {
        switch place(of: id) {
        case .draft: nil
        case .temporaryRoom(let record):
            if record.state == .finalized { String(localized: "Splitting now · waiting for payments") } else { String(localized: "Splitting now") }
        case .groupReceipt(_, let name, _): String(localized: "Posted to \(name) · waiting for claims")
        }
    }
}

extension AppRouter {
    /// Opens a receipt where it lives now: its group, or its own flow (a draft or a live room).
    func open(_ id: ReceiptRoomID, in environment: AppEnvironment) {
        if case .groupReceipt(let groupID, _, _) = environment.place(of: id) {
            openGroupReceipt(id, in: groupID)
        } else {
            openReceipt(id)
        }
    }
}
