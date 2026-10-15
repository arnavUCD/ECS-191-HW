import Foundation

/// Translates between the app's receipt-room model and the `/v1` wire format.
///
/// Participant IDs on the server are the room's member IDs: the host's group members keep their
/// `MemberID`, and people who join through an invitation get new IDs. A remote room is shown
/// with the same screens as a local one by building a *workspace* snapshot: the room, its
/// participants as members, and a group made of exactly those participants — the same context
/// the server uses for readiness.
nonisolated enum RemoteRoomMapper {
    nonisolated enum Failure: Error, Equatable, Sendable {
        /// A local-only command (drafts, setup, participant picking) has no remote equivalent.
        case unsupportedCommand
        case receiptIncomplete
    }

    // MARK: - Dates

    /// Receipt dates travel as calendar days (`YYYY-MM-DD`) in the person's own time zone.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// Server timestamps: ISO 8601 UTC with microseconds (`2026-09-25T12:00:00.000000Z`).
    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + text[dot..<zone]) ?? 0
            whole = String(text[..<dot] + text[zone...])
        }
        guard let date = try? Date(whole, strategy: .iso8601) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    // MARK: - Domain → wire

    static func receipt(_ draft: ReceiptDraft, calendar: Calendar = .current) -> ReceiptDTO {
        ReceiptDTO(
            merchant: draft.merchant.value.trimmingCharacters(in: .whitespacesAndNewlines),
            date: day(draft.date.value, calendar: calendar),
            currency: draft.currencyCode.rawValue,
            total: draft.total.value.map { Int($0.minorUnits) },
            subtotal: draft.subtotal.value.map { Int($0.minorUnits) },
            items: draft.items.map { item in
                ItemDTO(id: id(item.id), name: item.name.value, lineTotal: Int(item.amount.minorUnits), quantity: item.quantity,
                        unitPrice: item.unitPrice.map { Int($0.minorUnits) }, isRefund: item.isRefund)
            },
            charges: draft.charges.map { charge in
                ChargeDTO(id: id(charge.id), kind: charge.kind.rawValue, label: charge.label, amount: Int(charge.value.minorUnits),
                          allocation: rule(charge.allocation))
            }
        )
    }

    static func rule(_ allocation: ChargeAllocation) -> AllocationRuleDTO {
        switch allocation {
        case .proportional: AllocationRuleDTO(kind: "proportional")
        case .payer: AllocationRuleDTO(kind: "payer")
        case .equal(let members): AllocationRuleDTO(kind: "equal", members: members?.map(id))
        case .shares(let weights):
            AllocationRuleDTO(kind: "shares", weights: weights.map { ParticipantWeightDTO(participantId: id($0.memberID), weight: $0.weight) })
        case .exact(let shares):
            AllocationRuleDTO(kind: "exact", amounts: shares.map { ParticipantAmountDTO(participantId: id($0.memberID), amount: Int($0.amount.minorUnits)) })
        }
    }

    static func rule(_ split: ItemSplit) -> AllocationRuleDTO {
        switch split {
        case .equal(let members): AllocationRuleDTO(kind: "equal", members: members.map(id))
        case .shares(let weights):
            AllocationRuleDTO(kind: "shares", weights: weights.map { ParticipantWeightDTO(participantId: id($0.memberID), weight: $0.weight) })
        case .exact(let shares):
            AllocationRuleDTO(kind: "exact", amounts: shares.map { ParticipantAmountDTO(participantId: id($0.memberID), amount: Int($0.amount.minorUnits)) })
        case .units(let counts):
            AllocationRuleDTO(kind: "units", units: counts.map { ParticipantUnitsDTO(participantId: id($0.memberID), units: $0.units) })
        }
    }

    static func mode(_ mode: ClaimMode) -> ClaimModeDTO {
        switch mode {
        case .full: ClaimModeDTO(kind: "full")
        case .equalShare: ClaimModeDTO(kind: "equalShare")
        case .shares(let count): ClaimModeDTO(kind: "shares", shares: count)
        case .exact(let amount): ClaimModeDTO(kind: "exact", amount: Int(amount.minorUnits))
        case .units(let count): ClaimModeDTO(kind: "units", units: count)
        }
    }

    /// Publishing a local room (milestone 4 §4.3 "transition from local rooms"): its participants
    /// become seats, existing claims carry over, and the room keeps its identifier.
    static func publishRequest(for room: ReceiptRoom, in snapshot: LedgerSnapshot, calendar: Calendar = .current) throws(Failure) -> PublishRequest {
        guard let payerID = room.payerID, room.receipt.total.value != nil else { throw .receiptIncomplete }
        var people = room.participantIDs
        if !people.contains(room.hostID) { people.insert(room.hostID, at: 0) }
        if !people.contains(payerID) { people.append(payerID) }
        return PublishRequest(
            roomId: id(room.id), hostParticipantId: id(room.hostID), payerId: id(payerID),
            participants: people.map { member in
                PublishRequest.Person(id: id(member), displayName: String((snapshot.members[member]?.displayName ?? "Guest").prefix(40)))
            },
            receipt: receipt(room.receipt, calendar: calendar),
            claims: room.claims.map { ClaimDTO(itemId: id($0.itemID), participantId: id($0.memberID), mode: mode($0.mode)) },
            payerAcceptsFullReceipt: room.payerAcceptsFullReceipt
        )
    }

    /// A room command as a server command (`type`, `payload`).
    static func command(_ command: ReceiptRoomCommand, calendar: Calendar = .current) throws(Failure) -> (type: String, payload: JSONValue) {
        switch command {
        case .claim(_, _, let item, let request):
            return ("claim", ["itemId": .string(id(item)), "request": request == .mine ? "mine" : "share"])
        case .unclaim(_, _, let item):
            return ("unclaim", ["itemId": .string(id(item))])
        case .claimUnits(_, _, let item, let units):
            return ("claimUnits", ["itemId": .string(id(item)), "units": .int(units)])
        case .setItemSplit(_, _, let item, let split):
            return ("setItemSplit", ["itemId": .string(id(item)), "split": json(rule(split))])
        case .dispute(_, _, let target, let note):
            var payload: [String: JSONValue] = ["target": targetJSON(target)]
            if let note { payload["note"] = .string(note) }
            return ("dispute", .object(payload))
        case .resolveDispute(_, _, let disputeID, let status, let note):
            var payload: [String: JSONValue] = ["disputeId": .string(id(disputeID)), "status": .string(status.rawValue)]
            if let note { payload["note"] = .string(note) }
            return ("resolveDispute", .object(payload))
        case .setChargeAllocation(_, _, let charge, let allocation):
            return ("setChargeAllocation", ["chargeId": .string(id(charge)), "allocation": json(rule(allocation))])
        case .reviseReceipt(_, _, let draft):
            return ("reviseReceipt", ["receipt": json(receipt(draft, calendar: calendar))])
        case .markReviewed:
            return ("markReviewed", [:])
        case .setPayerAcceptsFullReceipt(_, _, let accepts):
            return ("setPayerAcceptsFullReceipt", ["accepts": .bool(accepts)])
        case .transition(_, _, let move):
            let name = switch move {
            case .beginResolving: "beginResolving"
            case .reopenClaims: "reopenClaims"
            case .requestFinalReview: "requestFinalReview"
            case .returnToRoom: "returnToRoom"
            }
            return ("transition", ["move": .string(name)])
        case .finalize(_, _, let acknowledging):
            // Only sent when the host acknowledged someone's unreviewed share (older rooms never need it).
            if acknowledging.isEmpty { return ("finalize", [:]) }
            return ("finalize", ["acknowledgeUnreviewed": .array(acknowledging.map { .string(id($0)) })])
        case .cancel:
            return ("cancel", [:])
        case .createDraft, .saveDraft, .confirmReceipt, .reopenReview, .openRoom, .setParticipants, .discardDraft, .markImagesRemoved,
             .adoptShared:
            throw .unsupportedCommand
        }
    }

    private static func targetJSON(_ target: DisputeTarget) -> JSONValue {
        switch target {
        case .item(let item): ["kind": "item", "id": .string(id(item))]
        case .charge(let charge): ["kind": "charge", "id": .string(id(charge))]
        }
    }

    private static func json(_ value: some Encodable) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }

    // MARK: - Wire → domain

    /// The room as the app models it. `base` (the host's own local room) keeps receipt evidence
    /// — images, recognized regions, edit history — that never leaves the host's iPhone.
    static func room(_ dto: RoomDTO, base: ReceiptRoom?, groupID: GroupID, finalExpenseID: ExpenseID? = nil,
                     calendar: Calendar = .current) -> ReceiptRoom {
        let currency = CurrencyCode(dto.receipt.currency)
        let updated = timestamp(dto.updatedAt) ?? .now
        let receipt = draft(dto.receipt, base: base?.receipt, calendar: calendar, at: updated)
        var room = ReceiptRoom(id: ReceiptRoomID(string: dto.roomId) ?? ReceiptRoomID(), groupID: groupID,
                               hostID: member(dto.hostParticipantId), receipt: receipt, createdAt: base?.createdAt ?? updated)
        room.payerID = dto.payerId.map(member)
        room.state = ReceiptRoomState(rawValue: dto.state) ?? .open
        room.participantIDs = dto.participantOrder.map(member)
        room.claims = dto.claims.compactMap { claim in
            guard let item = ReceiptItemID(string: claim.itemId) else { return nil }
            return ReceiptClaim(itemID: item, memberID: member(claim.participantId), mode: mode(claim.mode, currency),
                                createdAt: updated, updatedAt: updated, revision: dto.revision)
        }
        room.disputes = dto.disputes.compactMap { dispute in
            guard let disputeID = ReceiptDisputeID(string: dispute.id) else { return nil }
            let target: DisputeTarget
            if dispute.target.kind == "charge", let charge = ReceiptChargeID(string: dispute.target.id) {
                target = .charge(charge)
            } else if let item = ReceiptItemID(string: dispute.target.id) {
                target = .item(item)
            } else {
                return nil
            }
            return ReceiptDispute(id: disputeID, target: target, raisedBy: member(dispute.raisedBy), note: dispute.note,
                                  createdAt: timestamp(dispute.createdAt) ?? updated, status: DisputeStatus(rawValue: dispute.status) ?? .open,
                                  resolvedBy: dispute.resolvedBy.map(member), resolvedAt: timestamp(dispute.resolvedAt),
                                  resolutionNote: dispute.resolutionNote)
        }
        room.reviews = dto.reviews.map { ReviewMark(memberID: member($0.participantId), revision: $0.revision) }
        room.needsReview = dto.needsReview.map(member)
        room.payerAcceptsFullReceipt = dto.payerAcceptsFullReceipt
        room.revision = dto.revision
        room.history = base?.history ?? []
        room.confirmedAt = base?.confirmedAt
        room.openedAt = base?.openedAt ?? room.createdAt
        if let finalization = dto.finalization {
            room.finalizedAt = timestamp(finalization.finalizedAt)
            room.finalExpenseID = finalExpenseID
        }
        if room.state == .cancelled { room.cancelledAt = updated }
        return room
    }

    static func draft(_ dto: ReceiptDTO, base: ReceiptDraft?, calendar: Calendar, at date: Date) -> ReceiptDraft {
        let currency = CurrencyCode(dto.currency)
        func money(_ minor: Int) -> Money { Money(minorUnits: Int64(minor), currency: currency) }
        let day = self.date(fromDay: dto.date, calendar: calendar) ?? date
        var draft = base ?? .empty(pages: [], currency: currency, date: day)
        draft.merchant.value = dto.merchant
        if base == nil || self.day(draft.date.value, calendar: calendar) != dto.date { draft.date.value = day }
        draft.currency.value = currency
        draft.total.value = dto.total.map(money)
        draft.subtotal.value = dto.subtotal.map(money)
        draft.items = dto.items.compactMap { item in
            guard let itemID = ReceiptItemID(string: item.id) else { return nil }
            var line = base?.item(itemID)
                ?? ReceiptLineItem(id: itemID, name: ReceiptField(item.name), lineTotal: ReceiptField(money(item.lineTotal)))
            line.name.value = item.name
            line.lineTotal.value = money(item.lineTotal)
            line.quantity = item.quantity
            line.unitPrice = item.unitPrice.map(money)
            line.isRefund = item.isRefund
            return line
        }
        draft.charges = dto.charges.compactMap { charge in
            guard let chargeID = ReceiptChargeID(string: charge.id) else { return nil }
            let kind = ReceiptChargeKind(rawValue: charge.kind) ?? .adjustment
            var line = base?.charge(chargeID)
                ?? ReceiptCharge(id: chargeID, kind: kind, label: charge.label, amount: ReceiptField(money(charge.amount)))
            line.kind = kind
            line.label = charge.label
            line.amount.value = money(charge.amount)
            line.allocation = allocation(charge.allocation, currency)
            return line
        }
        return draft
    }

    static func allocation(_ rule: AllocationRuleDTO, _ currency: CurrencyCode) -> ChargeAllocation {
        switch rule.kind {
        case "payer": .payer
        case "equal": .equal(rule.members?.map(member))
        case "shares": .shares((rule.weights ?? []).map { MemberWeight(member($0.participantId), $0.weight) })
        case "exact": .exact((rule.amounts ?? []).map { Share(member($0.participantId), Money(minorUnits: Int64($0.amount), currency: currency)) })
        default: .proportional
        }
    }

    static func mode(_ dto: ClaimModeDTO, _ currency: CurrencyCode) -> ClaimMode {
        switch dto.kind {
        case "full": .full
        case "shares": .shares(dto.shares ?? 1)
        case "exact": .exact(Money(minorUnits: Int64(dto.amount ?? 0), currency: currency))
        case "units": .units(dto.units ?? 1)
        default: .equalShare
        }
    }

    /// Everything the room screens read, for one viewer. Local member details (handles, names
    /// the host knows) win over the names in the room.
    static func workspace(_ dto: RoomDTO, room: ReceiptRoom, local: LedgerSnapshot?, groupName: String?) -> LedgerSnapshot {
        let currency = CurrencyCode(dto.receipt.currency)
        let members = dto.participants.map { participant in
            let id = member(participant.id)
            return local?.members[id] ?? Member(id: id, displayName: participant.displayName)
        }
        let removedAt = timestamp(dto.updatedAt) ?? .now
        let group = ExpenseGroup(
            id: room.groupID ?? GroupID(room.id.rawValue), name: groupName ?? room.title, currency: currency,
            symbolName: "receipt", memberships: dto.participants.map {
                Membership(memberID: member($0.id), removedAt: $0.removed ? removedAt : nil)
            }, createdAt: room.createdAt
        )
        return LedgerSnapshot(currentUserID: member(dto.viewer.participantId), members: members, groups: [group], expenses: [],
                              settlements: [], defaultCurrency: currency, receiptRooms: [room])
    }

    /// Server totals by participant, to compare with the app's own allocation (drift check).
    static func totals(_ participants: [ParticipantTotalDTO], _ currency: CurrencyCode) -> [MemberID: Money] {
        Dictionary(participants.map { (member($0.participantId), Money(minorUnits: Int64($0.total), currency: currency)) },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Identifiers

    static func id<Tag>(_ identifier: Identifier<Tag>) -> String { identifier.rawValue.uuidString.lowercased() }

    static func member(_ raw: String) -> MemberID {
        MemberID(string: raw) ?? MemberID(UUID(uuid: UUID.nameBased(raw)))
    }
}

private extension UUID {
    /// A deterministic UUID for a malformed identifier (never expected from the server).
    nonisolated static func nameBased(_ text: String) -> uuid_t {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in text.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &* 31 &+ byte }
        return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }
}

nonisolated extension ReceiptRoomCommand {
    /// The same command based on a different room revision (optimistic preview of queued taps).
    func rebased(to revision: Int) -> ReceiptRoomCommand {
        switch self {
        case .saveDraft(let id, _, let receipt, let group, let payer): .saveDraft(id, expectedRevision: revision, receipt: receipt, groupID: group, payerID: payer)
        case .confirmReceipt(let id, _): .confirmReceipt(id, expectedRevision: revision)
        case .reopenReview(let id, _): .reopenReview(id, expectedRevision: revision)
        case .openRoom(let id, _, let people): .openRoom(id, expectedRevision: revision, participants: people)
        case .setParticipants(let id, _, let people): .setParticipants(id, expectedRevision: revision, participants: people)
        case .claim(let id, _, let item, let request): .claim(id, expectedRevision: revision, item: item, request)
        case .unclaim(let id, _, let item): .unclaim(id, expectedRevision: revision, item: item)
        case .claimUnits(let id, _, let item, let units): .claimUnits(id, expectedRevision: revision, item: item, units: units)
        case .setItemSplit(let id, _, let item, let split): .setItemSplit(id, expectedRevision: revision, item: item, split)
        case .dispute(let id, _, let target, let note): .dispute(id, expectedRevision: revision, target, note: note)
        case .resolveDispute(let id, _, let dispute, let status, let note):
            .resolveDispute(id, expectedRevision: revision, dispute, status, note: note)
        case .setChargeAllocation(let id, _, let charge, let allocation): .setChargeAllocation(id, expectedRevision: revision, charge, allocation)
        case .reviseReceipt(let id, _, let receipt): .reviseReceipt(id, expectedRevision: revision, receipt)
        case .markReviewed(let id, _): .markReviewed(id, expectedRevision: revision)
        case .setPayerAcceptsFullReceipt(let id, _, let accepts): .setPayerAcceptsFullReceipt(id, expectedRevision: revision, accepts)
        case .transition(let id, _, let move): .transition(id, expectedRevision: revision, move)
        case .finalize(let id, _, let acknowledging): .finalize(id, expectedRevision: revision, acknowledging: acknowledging)
        case .cancel(let id, _): .cancel(id, expectedRevision: revision)
        case .createDraft, .discardDraft, .markImagesRemoved, .adoptShared: self
        }
    }
}
