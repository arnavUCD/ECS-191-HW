import Foundation

/// Payment-destination reveals and receipts for a shared group (milestone 7 §10.1, §9). Split from
/// `SharedGroupLedger.swift` for size; same type, same rules.
extension SharedGroupLedger {

    // MARK: - Payment destinations (§10.1)

    /// Fetches a member's payment methods for the payment flow. The server answers only while
    /// this person owes them; otherwise the flow offers cash or "other".
    func revealDestinations(of member: MemberID) async throws {
        do {
            let dto = try await api.revealDestinations(group: SharedGroupMapper.id(groupID), member: SharedGroupMapper.id(member))
            revealed[member] = dto.destinations.compactMap { SharedGroupMapper.destination($0, owner: member) }
            rebuild()
        } catch {
            if case .server(let refusal) = error, refusal.code == "reveal_not_allowed" {
                revealed[member] = []
                rebuild()
                return
            }
            throw LedgerError.from(error)
        }
    }

    // MARK: - Receipts

    /// Whether a receipt draft or room started on this iPhone belongs to this group.
    func holdsRoom(_ id: ReceiptRoomID) -> Bool { rooms.contains { $0.id == id } }

    /// Receipt drafts and rooms for this group live on this iPhone until they become an expense.
    /// Finalizing sends one itemized expense with its frozen allocation; the expense ID is the room
    /// ID, so a retry or double tap can never save it twice.
    func performReceipt(_ command: ReceiptRoomCommand) async throws -> LedgerCommandResult {
        let workspace = try await snapshot()
        guard let viewer = viewerID else { throw LedgerError.remote(.unavailable) }
        if case .adoptShared = command {
            throw LedgerError.remote(.refused(String(localized: "Shared receipts are saved by their host.")))
        }
        let local = try LedgerEngine.perform(.receipt(command), on: workspace, actor: viewer, now: now())
        if case .finalize = command {
            guard let room = local.changes.compactMap({ if case .upsertRoom(let room) = $0 { room } else { nil } }).last,
                  room.state == .finalized else { return local } // already finalized: idempotent
            if base?.expenses.contains(where: { $0.id == SharedGroupMapper.id(room.id) }) == true {
                apply(roomChanges: local.changes)
                return local
            }
            guard let expense = local.changes.compactMap({ if case .upsertExpense(let expense) = $0 { expense } else { nil } }).first,
                  let snapshot = room.finalSnapshot, let current = base else { throw LedgerError.unavailable }
            let envelope = GroupCommandEnvelope(type: "addExpense", payload: SharedGroupMapper.expensePayload(expense, previous: nil, receipt: snapshot),
                                                expectedRevision: current.revision, knownCursor: current.cursor)
            let wire = SharedGroupMapper.WireCommand(type: "addExpense", payload: envelope.payload, isRevisionStrict: false, requiresLiveResponse: true)
            let summary = String(localized: "Save \(room.title)")
            _ = try await deliverAndAccept(envelope, wire: wire, command: nil, summary: summary, local: local, previewID: nil)
            apply(roomChanges: local.changes)
            return local
        }
        apply(roomChanges: local.changes)
        return local
    }

    /// Records a finalized shared Live Receipt Room (milestone 4) as this group's expense, once.
    /// `guestLinks` maps each guest participant the host matched to a group member.
    func adoptRemoteRoom(_ roomID: ReceiptRoomID, guestLinks: [String: MemberID]) async throws -> ExpenseID {
        guard let current = base else { throw LedgerError.remote(.unavailable) }
        let mapping: [String: JSONValue] = Dictionary(uniqueKeysWithValues: guestLinks.map { ($0.key, .string(SharedGroupMapper.id($0.value))) })
        let envelope = GroupCommandEnvelope(type: "adoptRoom", payload: ["roomId": .string(SharedGroupMapper.id(roomID)), "guestMembers": .object(mapping)],
                                            expectedRevision: current.revision, knownCursor: current.cursor)
        let wire = SharedGroupMapper.WireCommand(type: "adoptRoom", payload: envelope.payload, isRevisionStrict: false, requiresLiveResponse: true)
        let result = try await enqueue {
            try await self.deliverAndAccept(envelope, wire: wire, command: nil, summary: String(localized: "Save the shared receipt"), local: nil,
                                            previewID: nil)
        }
        if let index = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[index].state = .finalized
            rooms[index].finalExpenseID = ExpenseID(roomID.rawValue)
            persist()
            rebuild()
        }
        return result.expenseID ?? ExpenseID(roomID.rawValue)
    }

    func apply(roomChanges changes: [LedgerChange]) {
        for change in changes {
            switch change {
            case .upsertRoom(let room):
                if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room } else { rooms.append(room) }
            case .deleteRoom(let id):
                rooms.removeAll { $0.id == id }
            default:
                continue // money and history come from the server
            }
        }
        persist()
        rebuild()
    }
}
