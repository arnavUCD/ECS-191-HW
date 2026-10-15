import Foundation

/// Server events and frozen receipt splits (milestone 7). Split from `SharedGroupMapper.swift` for size.
nonisolated extension SharedGroupMapper {

    // MARK: - Events

    /// A server event as an audit event. Unknown kinds are skipped (forward compatibility); a
    /// known kind with malformed data fails the mapping.
    static func event(_ dto: GroupEventDTO, groupID: GroupID, currency: CurrencyCode) throws(Failure) -> AuditEvent? {
        let data = dto.data
        func member(_ key: String) throws(Failure) -> MemberID {
            guard let raw = data[key]?.stringValue else { throw .malformed("event.\(key)") }
            return try identifier(raw, key)
        }
        func optionalMember(_ key: String) throws(Failure) -> MemberID? {
            guard let raw = data[key]?.stringValue else { return nil }
            return try identifier(raw, key)
        }
        func text(_ key: String) -> String { data[key]?.stringValue ?? "" }
        func money(_ key: String) throws(Failure) -> Money {
            guard let units = data[key]?.intValue else { throw .malformed("event.\(key)") }
            return Money(minorUnits: Int64(units), currency: currency)
        }
        func info() throws(Failure) -> PaymentEventInfo {
            PaymentEventInfo(attemptID: try identifier(text("attemptId"), "attemptId"), payerID: try member("payerId"),
                             recipientID: try member("recipientId"), amount: try money("amount"),
                             provider: PaymentProviderKind(rawValue: text("provider")) ?? .other)
        }
        func revision(_ key: String) throws(Failure) -> ExpenseRevision {
            guard let raw = data[key] else { throw .malformed("event.\(key)") }
            guard let method = SplitMethod(rawValue: raw["splitMethod"]?.stringValue ?? ""),
                  let category = ExpenseCategory(rawValue: raw["category"]?.stringValue ?? ""),
                  let total = raw["total"]?.intValue else { throw .malformed("event.revision") }
            func list(_ name: String) throws(Failure) -> [Share] {
                guard case .array(let entries) = raw[name] ?? .array([]) else { throw .malformed("event.revision") }
                return try entries.map { entry throws(Failure) in
                    guard let memberID = entry["memberId"]?.stringValue, let amount = entry["amount"]?.intValue else { throw .malformed("event.share") }
                    return Share(try identifier(memberID, "memberId"), Money(minorUnits: Int64(amount), currency: currency))
                }
            }
            return ExpenseRevision(revision: raw["revision"]?.intValue ?? 1, title: raw["title"]?.stringValue ?? "",
                                   total: Money(minorUnits: Int64(total), currency: currency),
                                   date: (try? timestamp(raw["date"]?.stringValue ?? "")) ?? .distantPast, category: category,
                                   splitMethod: method, payments: try list("payments"), allocations: try list("allocations"))
        }

        let kind: AuditEvent.Kind
        switch dto.kind {
        case "groupCreated": kind = .groupCreated(name: text("name"))
        case "groupPublished": kind = .groupPublished(name: text("name"))
        case "groupEdited":
            guard case .array(let fields) = data["fields"] ?? .array([]) else { throw .malformed("event.fields") }
            kind = .groupEdited(fields: fields.compactMap { $0.stringValue.flatMap(GroupField.init(rawValue:)) })
        case "groupArchived": kind = .groupArchived
        case "simplificationChanged": kind = .simplificationChanged(enabled: data["enabled"] == .bool(true))
        case "memberAdded": kind = .memberAdded(try member("memberId"))
        case "memberInvited": kind = .memberInvited(seat: try optionalMember("seatMemberId"))
        case "memberJoined": kind = .memberJoined(try member("memberId"))
        case "memberRemoved": kind = .memberRemoved(try member("memberId"))
        case "memberLeft": kind = .memberLeft(try member("memberId"))
        case "ownershipTransferred": kind = .ownershipTransferred(from: try member("fromMemberId"), to: try member("toMemberId"))
        case "expenseCreated":
            kind = .expenseCreated(try identifier(text("expenseId"), "expenseId"), title: text("title"), total: try money("total"))
        case "expenseEdited":
            guard case .array(let fields) = data["fields"] ?? .array([]) else { throw .malformed("event.fields") }
            kind = .expenseEdited(try identifier(text("expenseId"), "expenseId"), title: text("title"),
                                  fields: fields.compactMap { $0.stringValue.flatMap(ExpenseField.init(rawValue:)) },
                                  previous: try revision("previous"), revision: data["revision"]?.intValue ?? 1)
        case "expenseDeleted": kind = .expenseDeleted(try identifier(text("expenseId"), "expenseId"), snapshot: try revision("snapshot"))
        case "expenseRestored": kind = .expenseRestored(try identifier(text("expenseId"), "expenseId"), title: text("title"))
        case "receiptRoomAdopted":
            kind = .receiptRoomAdopted(try identifier(text("roomId"), "roomId"), expenseID: try identifier(text("expenseId"), "expenseId"),
                                       title: text("title"))
        case "receiptRoomOpened":
            kind = .receiptRoomOpened(try identifier(text("roomId"), "roomId"), title: text("title"),
                                      participantCount: data["participantCount"]?.intValue ?? 0)
        case "receiptRoomFinalized":
            guard let expenseID = data["expenseId"]?.stringValue else { return nil } // the expense wasn't shared
            kind = .receiptRoomFinalized(try identifier(text("roomId"), "roomId"), expenseID: try identifier(expenseID, "expenseId"),
                                         title: text("title"))
        case "receiptRoomCancelled": kind = .receiptRoomCancelled(try identifier(text("roomId"), "roomId"), title: text("title"))
        case "settlementRecorded":
            guard let settlementID = data["settlementId"]?.stringValue else { return nil }
            kind = .settlementRecorded(try identifier(settlementID, "settlementId"), fromID: try member("fromId"), toID: try member("toId"),
                                       amount: try money("amount"))
        case "paymentStarted": kind = .paymentStarted(try info())
        case "paymentHandoffOpened": kind = .paymentHandoffOpened(try info())
        case "paymentReported": kind = .paymentReported(try info())
        case "paymentConfirmed":
            kind = .paymentConfirmed(try info(), settlementID: try identifier(text("settlementId"), "settlementId"))
        case "paymentRejected": kind = .paymentRejected(try info(), reason: nil)
        case "paymentDisputed": kind = .paymentDisputed(try info(), reason: nil)
        case "paymentCancelled":
            kind = .paymentCancelled(try info(), reason: PaymentCancelReason(rawValue: text("reason")) ?? .payerCancelled)
        default:
            return nil
        }
        return AuditEvent(id: try identifier(dto.id, "event.id"), groupID: groupID, actorID: try identifier(dto.actorMemberId, "actor"),
                          date: try timestamp(dto.at), sequence: dto.sequence, kind: kind)
    }

    // MARK: - Receipts

    /// A read-only, finalized room for an itemized expense, so expense detail shows the item split.
    static func displayRoom(_ dto: ReceiptSnapshotDTO, expense: Expense, currency: CurrencyCode) throws(Failure) -> ReceiptRoom {
        func money(_ units: Int) -> Money { Money(minorUnits: Int64(units), currency: currency) }
        let items = try dto.items.map { item throws(Failure) in
            ReceiptAllocationSnapshot.Item(id: try identifier(item.id, "item.id"), name: item.name, quantity: item.quantity,
                                           lineTotal: money(item.lineTotal), isRefund: item.isRefund, shares: try shares(item.shares, currency))
        }
        let charges = try dto.charges.map { charge throws(Failure) in
            guard let kind = ReceiptChargeKind(rawValue: charge.kind) else { throw .malformed("charge.kind") }
            let rule = (try? JSONDecoder().decode(AllocationRuleDTO.self, from: JSONEncoder().encode(charge.allocation)))
                ?? AllocationRuleDTO(kind: "proportional")
            return ReceiptAllocationSnapshot.Charge(id: try identifier(charge.id, "charge.id"), kind: kind, label: charge.label, amount: money(charge.amount),
                                                    allocation: RemoteRoomMapper.allocation(rule, currency), shares: try shares(charge.shares, currency))
        }
        let participants = try dto.participants.map { participant throws(Failure) in
            ParticipantTotal(memberID: try identifier(participant.memberId, "participant"), items: money(participant.items), tax: money(participant.tax),
                             tip: money(participant.tip), fees: money(participant.fees), discounts: money(participant.discounts),
                             adjustments: money(participant.adjustments), itemShares: [])
        }
        let rounding = try dto.rounding.map { note throws(Failure) in
            let source: RoundingNote.Source = note.sourceKind == "charge"
                ? .charge(try identifier(note.sourceId, "rounding.source")) : .item(try identifier(note.sourceId, "rounding.source"))
            return RoundingNote(source: source, memberID: try identifier(note.memberId, "rounding.member"), amount: money(note.amount))
        }
        var draft = ReceiptDraft.empty(pages: [], currency: currency, date: expense.date)
        draft.merchant = ReceiptField(dto.merchant, attention: .looksGood, reason: .confirmedByPerson)
        var room = ReceiptRoom(id: ReceiptRoomID(expense.id.rawValue), groupID: expense.groupID, hostID: expense.createdBy, receipt: draft,
                               createdAt: expense.createdAt)
        room.state = .finalized
        room.finalExpenseID = expense.id
        room.finalizedAt = expense.createdAt
        room.payerID = expense.payments.first?.memberID
        room.finalSnapshot = ReceiptAllocationSnapshot(
            merchant: dto.merchant, date: expense.date, total: money(dto.total), items: items, charges: charges, participants: participants,
            payments: expense.payments, rounding: rounding, roomRevision: 0, finalizedAt: expense.createdAt, finalizedBy: expense.createdBy
        )
        return room
    }

    /// The frozen allocation of a room finalized on this device, as the server stores it.
    static func receipt(_ snapshot: ReceiptAllocationSnapshot) -> ReceiptSnapshotDTO {
        func shares(_ list: [Share]) -> [ShareDTO] { list.map { ShareDTO(memberId: id($0.memberID), amount: Int($0.amount.minorUnits)) } }
        func json(_ value: some Encodable) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .object(["kind": "proportional"])
        }
        return ReceiptSnapshotDTO(
            merchant: snapshot.merchant, date: iso(snapshot.date), total: Int(snapshot.total.minorUnits),
            items: snapshot.items.map {
                ReceiptSnapshotDTO.Item(id: id($0.id), name: $0.name, quantity: $0.quantity, lineTotal: Int($0.lineTotal.minorUnits),
                                        isRefund: $0.isRefund, shares: shares($0.shares))
            },
            charges: snapshot.charges.map {
                ReceiptSnapshotDTO.Charge(id: id($0.id), kind: $0.kind.rawValue, label: $0.label, amount: Int($0.amount.minorUnits),
                                          allocation: json(RemoteRoomMapper.rule($0.allocation)), shares: shares($0.shares))
            },
            participants: snapshot.participants.filter { !$0.total.isZero }.map {
                ReceiptSnapshotDTO.Participant(memberId: id($0.memberID), items: Int($0.items.minorUnits), tax: Int($0.tax.minorUnits),
                                               tip: Int($0.tip.minorUnits), fees: Int($0.fees.minorUnits),
                                               discounts: Int($0.discounts.minorUnits), adjustments: Int($0.adjustments.minorUnits),
                                               total: Int($0.total.minorUnits))
            },
            rounding: snapshot.rounding.map { note in
                let (kind, source): (String, String) = switch note.source {
                case .item(let item): ("item", id(item))
                case .charge(let charge): ("charge", id(charge))
                }
                return ReceiptSnapshotDTO.Rounding(sourceKind: kind, sourceId: source, memberId: id(note.memberID), amount: Int(note.amount.minorUnits))
            }
        )
    }
}
