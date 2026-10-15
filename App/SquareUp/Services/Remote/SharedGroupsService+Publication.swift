import Foundation

/// The pure rules for publishing a local group and reading invitation codes (milestone 7 §4, §8).
/// Split from `SharedGroupsService.swift` for size.
extension SharedGroupsService {
    nonisolated static func review(_ groupID: GroupID, in snapshot: LedgerSnapshot) -> PublicationReview {
        var blockers: [String] = []
        var disclosures: [String] = []
        // Legacy organization records never appear in a snapshot (`LegacyRecords`), so they can't be published.
        guard let group = snapshot.group(groupID) else {
            return PublicationReview(blockers: [String(localized: "Only your own personal groups can be shared.")], disclosures: [],
                                     memberCount: 0, expenseCount: 0)
        }
        if !group.isActiveMember(snapshot.currentUserID) {
            blockers.append(String(localized: "You need to be a member of this group to share it."))
        }
        let expenses = snapshot.allExpenses.filter { $0.groupID == groupID }
        for expense in expenses where expense.currency != group.currency {
            blockers.append(String(localized: "\(expense.title) uses a different currency than the group."))
        }
        for expense in expenses {
            do {
                try ExpenseValidator.validate(expense, in: group)
            } catch {
                blockers.append(String(localized: "\(expense.title) doesn't add up. Edit it before sharing."))
            }
        }
        if snapshot.attempts(in: groupID).contains(where: { !$0.state.isTerminal }) {
            blockers.append(String(localized: "Finish or cancel payments in progress first."))
        }
        let unfinished = snapshot.unfinishedRooms(in: groupID).count
        if unfinished > 0 {
            blockers.append(Inflect.string("Finish or discard ^[\(unfinished) receipt](inflect: true) in progress first."))
        }
        let ids = [groupID.rawValue] + expenses.map(\.id.rawValue) + snapshot.settlements(in: groupID).map(\.id.rawValue)
        if Set(ids).count != ids.count { blockers.append(String(localized: "Some records in this group are duplicated.")) }
        let others = group.memberIDs.filter { $0 != snapshot.currentUserID && group.isActiveMember($0) }.count
        disclosures.append(String(localized: "Everyone's names, every expense, and recorded payments are shared with the people who join."))
        if others > 0 {
            disclosures.append(Inflect.string("^[\(others) person](inflect: true) will wait for an invitation. Each joins as themselves — nobody is matched by name."))
        }
        if expenses.contains(where: { $0.splitMethod == .itemized }) {
            disclosures.append(String(localized: "Receipt images and item details stay on this iPhone; the split amounts are shared."))
        }
        disclosures.append(String(localized: "Payment methods aren't copied. Each person adds their own."))
        disclosures.append(String(localized: "After sharing, this group is kept in sync with the server, and the copy on this iPhone is set aside."))
        return PublicationReview(blockers: blockers, disclosures: disclosures, memberCount: group.memberIDs.count, expenseCount: expenses.count)
    }

    nonisolated static func publication(_ groupID: GroupID, in snapshot: LedgerSnapshot, publicationID: String) -> PublicationRequest {
        let group = snapshot.group(groupID)
        let iso = SharedGroupMapper.iso
        let id = { (identifier: UUID) in identifier.uuidString.lowercased() }
        func shares(_ list: [Share]) -> [ShareDTO] { list.map { ShareDTO(memberId: id($0.memberID.rawValue), amount: Int($0.amount.minorUnits)) } }
        let members = (group?.memberships ?? []).compactMap { membership -> PublicationRequest.Member? in
            guard let member = snapshot.members[membership.memberID] else { return nil }
            return PublicationRequest.Member(id: id(member.id.rawValue), displayName: member.displayName, handle: member.handle,
                                             removed: !membership.isActive)
        }
        let expenses = snapshot.allExpenses.filter { $0.groupID == groupID }.map { expense in
            PublicationRequest.Expense(
                id: id(expense.id.rawValue), title: expense.title, merchant: expense.merchant, date: iso(expense.date),
                total: Int(expense.total.minorUnits), currency: expense.currency.rawValue, category: expense.category.rawValue,
                splitMethod: expense.splitMethod.rawValue, payments: shares(expense.payments), allocations: shares(expense.allocations),
                note: expense.note, createdBy: id(expense.createdBy.rawValue), createdAt: iso(expense.createdAt), revision: expense.revision,
                updatedAt: expense.updatedAt.map(iso), updatedBy: expense.updatedBy.map { id($0.rawValue) },
                deletedAt: expense.deletedAt.map(iso), deletedBy: expense.deletedBy.map { id($0.rawValue) }
            )
        }
        let settlements = snapshot.settlements(in: groupID).map { settlement in
            PublicationRequest.Settlement(id: id(settlement.id.rawValue), fromId: id(settlement.fromID.rawValue), toId: id(settlement.toID.rawValue),
                                          amount: Int(settlement.amount.minorUnits), date: iso(settlement.date),
                                          recordedBy: id(settlement.recordedBy.rawValue), provider: settlement.provider?.rawValue)
        }
        let events = snapshot.events(in: groupID).compactMap { event -> PublicationRequest.Event? in
            guard let (kind, data) = eventWire(event.kind) else { return nil }
            return PublicationRequest.Event(kind: kind, actorMemberId: id(event.actorID.rawValue), at: iso(event.date), data: data)
        }
        return PublicationRequest(
            publicationId: publicationID, publisherMemberId: id(snapshot.currentUserID.rawValue),
            group: PublicationRequest.Group(id: id(groupID.rawValue), name: group?.name ?? "", details: group?.details, symbol: group?.symbolName ?? "person.3.fill",
                                            currency: group?.currency.rawValue ?? "USD", simplifiesDebts: group?.simplifiesDebts ?? true,
                                            createdAt: iso(group?.createdAt ?? .now)),
            members: members, expenses: expenses, settlements: settlements, events: events
        )
    }

    /// A local audit event in the server's event format (history kinds only; free text is dropped).
    nonisolated static func eventWire(_ kind: AuditEvent.Kind) -> (String, JSONValue)? {
        let id = { (identifier: UUID) -> JSONValue in .string(identifier.uuidString.lowercased()) }
        func revision(_ revision: ExpenseRevision) -> JSONValue {
            let shares = { (list: [Share]) -> JSONValue in
                .array(list.map { ["memberId": id($0.memberID.rawValue), "amount": .int(Int($0.amount.minorUnits))] })
            }
            return ["revision": .int(revision.revision), "title": .string(revision.title), "total": .int(Int(revision.total.minorUnits)),
                    "date": .string(SharedGroupMapper.iso(revision.date)), "category": .string(revision.category.rawValue),
                    "splitMethod": .string(revision.splitMethod.rawValue), "payments": shares(revision.payments), "allocations": shares(revision.allocations)]
        }
        func payment(_ info: PaymentEventInfo) -> [String: JSONValue] {
            ["attemptId": id(info.attemptID.rawValue), "payerId": id(info.payerID.rawValue), "recipientId": id(info.recipientID.rawValue),
             "amount": .int(Int(info.amount.minorUnits)), "provider": .string(info.provider.rawValue)]
        }
        switch kind {
        case .groupCreated(let name): return ("groupCreated", ["name": .string(name)])
        case .groupEdited(let fields): return ("groupEdited", ["fields": .array(fields.map { .string($0.rawValue) })])
        case .memberAdded(let member): return ("memberAdded", ["memberId": id(member.rawValue)])
        case .memberRemoved(let member): return ("memberRemoved", ["memberId": id(member.rawValue)])
        case .simplificationChanged(let enabled): return ("simplificationChanged", ["enabled": .bool(enabled)])
        case .expenseCreated(let expense, let title, let total):
            return ("expenseCreated", ["expenseId": id(expense.rawValue), "title": .string(title), "total": .int(Int(total.minorUnits))])
        case .expenseEdited(let expense, let title, let fields, let previous, let number):
            return ("expenseEdited", ["expenseId": id(expense.rawValue), "title": .string(title), "fields": .array(fields.map { .string($0.rawValue) }),
                                      "previous": revision(previous), "revision": .int(number)])
        case .expenseDeleted(let expense, let snapshot): return ("expenseDeleted", ["expenseId": id(expense.rawValue), "snapshot": revision(snapshot)])
        case .expenseRestored(let expense, let title): return ("expenseRestored", ["expenseId": id(expense.rawValue), "title": .string(title)])
        case .settlementRecorded(let settlement, let from, let to, let amount):
            return ("settlementRecorded", ["settlementId": id(settlement.rawValue), "fromId": id(from.rawValue), "toId": id(to.rawValue),
                                           "amount": .int(Int(amount.minorUnits))])
        case .paymentConfirmed(let info, let settlement):
            var data = payment(info)
            data["settlementId"] = id(settlement.rawValue)
            return ("paymentConfirmed", .object(data))
        case .receiptRoomFinalized(let room, let expense, let title):
            return ("receiptRoomFinalized", ["roomId": id(room.rawValue), "expenseId": id(expense.rawValue), "title": .string(title)])
        default:
            // Drafts, payment attempts in progress, and room activity are device-only history.
            return nil
        }
    }

    /// Group invitation codes from any source: `squp://join-group/<code>`, the HTTPS page, or pasted text.
    nonisolated static func invitationCode(from text: String, configuration: RemoteConfiguration?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == DeepLink.scheme, url.host()?.lowercased() == "join-group" {
                return normalizedCode(url.pathComponents.first { $0 != "/" } ?? "")
            }
            if scheme == "https" || scheme == "http" {
                guard let configuration, url.host()?.lowercased() == configuration.baseURL.host()?.lowercased(), url.port == configuration.baseURL.port else {
                    return nil
                }
                let parts = url.path().split(separator: "/")
                guard parts.count == 2, parts[0] == "g" else { return nil }
                return normalizedCode(String(parts[1]))
            }
            return nil
        }
        return normalizedCode(trimmed)
    }

    /// Crockford Base32 (as the server): any case, with or without separators.
    nonisolated static func normalizedCode(_ text: String) -> String? {
        guard text.count <= 64 else { return nil }
        let cleaned = text.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1")
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard cleaned.count == 20, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return cleaned
    }

    nonisolated static func displayCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let lower = code.index(code.startIndex, offsetBy: start)
            return String(code[lower..<code.index(lower, offsetBy: min(4, code.count - start))])
        }.joined(separator: "-")
    }
}
