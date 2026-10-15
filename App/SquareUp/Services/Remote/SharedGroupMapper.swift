import Foundation

/// Translates between the app's ledger model and the shared-group wire format (milestone 7).
///
/// A shared group is shown with the same screens as a local one by building a *workspace*
/// snapshot: the group, its members, its expenses, settlements, payment attempts, and history,
/// with the signed-in account's seat as the current user. Feature views and calculators can't
/// tell whether SwiftData or the server supplied it.
///
/// Mapping is strict: anything malformed (an unknown split method, a bad identifier, money that
/// doesn't reconcile with the server's own balances) fails the whole mapping, and the last good
/// state stays on screen (§14 "Server data fails client mapping").
nonisolated enum SharedGroupMapper {
    nonisolated enum Failure: Error, Equatable, Sendable {
        case malformed(String)
        /// The app's calculation of the mapped records disagrees with the server's balances.
        case balancesDiffer
        /// The command has no shared-group equivalent.
        case unsupportedCommand
    }

    // MARK: - Identifiers and time

    static func id<Tag>(_ identifier: Identifier<Tag>) -> String { identifier.rawValue.uuidString.lowercased() }

    static func identifier<Tag>(_ raw: String, _ field: String) throws(Failure) -> Identifier<Tag> {
        guard let value = Identifier<Tag>(string: raw) else { throw .malformed(field) }
        return value
    }

    /// Server and client timestamps (ISO 8601, with or without fractional seconds).
    static func timestamp(_ text: String) throws(Failure) -> Date {
        if let date = RemoteRoomMapper.timestamp(text) { return date }
        throw .malformed("timestamp")
    }

    /// Dates the app sends: ISO 8601 UTC with milliseconds.
    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    // MARK: - Snapshot → workspace

    static func workspace(
        _ dto: GroupSnapshotDTO,
        destinations: [PaymentDestination] = [],
        rooms: [ReceiptRoom] = []
    ) throws(Failure) -> LedgerSnapshot {
        let currency = CurrencyCode(dto.group.currency)
        let group = try group(dto.group, members: dto.members)
        let members = try dto.members.map { member throws(Failure) in
            Member(id: try identifier(member.id, "member.id"), displayName: member.displayName, handle: member.handle)
        }
        let expenses = try dto.expenses.map { item throws(Failure) in try expense(item, groupID: group.id, currency: currency) }
        let settlements = try dto.settlements.map { item throws(Failure) in
            try settlement(item, groupID: group.id, currency: currency)
        }
        let attempts = try dto.attempts.map { item throws(Failure) in try attempt(item, groupID: group.id, currency: currency) }
        var events: [AuditEvent] = []
        for event in dto.events {
            if let mapped = try self.event(event, groupID: group.id, currency: currency) { events.append(mapped) }
        }
        let shown = expenses.compactMap { expense -> ReceiptRoom? in
            guard let receipt = dto.expenses.first(where: { $0.id == id(expense.id) })?.receipt else { return nil }
            return try? displayRoom(receipt, expense: expense, currency: currency)
        }
        return LedgerSnapshot(
            currentUserID: try identifier(dto.viewer.memberId, "viewer"), members: members, groups: [group], expenses: expenses,
            settlements: settlements, paymentDestinations: destinations, paymentAttempts: attempts, events: events,
            defaultCurrency: currency, receiptRooms: rooms.filter { $0.groupID == group.id } + shown
        )
    }

    static func group(_ header: GroupHeaderDTO, members: [GroupMemberDTO]) throws(Failure) -> ExpenseGroup {
        let memberships = try members.map { member throws(Failure) in
            Membership(memberID: try identifier(member.id, "member.id"),
                       removedAt: member.status == "removed" ? try member.removedAt.map { text throws(Failure) in try timestamp(text) } ?? .distantPast : nil)
        }
        return ExpenseGroup(
            id: try identifier(header.id, "group.id"), name: header.name, currency: CurrencyCode(header.currency), symbolName: header.symbol,
            memberships: memberships, createdAt: try timestamp(header.createdAt), details: header.details,
            simplifiesDebts: header.simplifiesDebts
        )
    }

    static func shares(_ shares: [ShareDTO], _ currency: CurrencyCode) throws(Failure) -> [Share] {
        try shares.map { share throws(Failure) in Share(try identifier(share.memberId, "share.memberId"), Money(minorUnits: Int64(share.amount), currency: currency)) }
    }

    static func expense(_ dto: GroupExpenseDTO, groupID: GroupID, currency: CurrencyCode) throws(Failure) -> Expense {
        guard let category = ExpenseCategory(rawValue: dto.category), let method = SplitMethod(rawValue: dto.splitMethod) else {
            throw .malformed("expense.category")
        }
        return Expense(
            id: try identifier(dto.id, "expense.id"), groupID: groupID, title: dto.title, merchant: dto.merchant,
            date: try timestamp(dto.date), total: Money(minorUnits: Int64(dto.total), currency: currency), category: category,
            splitMethod: method, payments: try shares(dto.payments, currency), allocations: try shares(dto.allocations, currency),
            note: dto.note, createdBy: try identifier(dto.createdBy, "createdBy"), createdAt: try timestamp(dto.createdAt),
            revision: dto.revision, updatedAt: try dto.updatedAt.map { text throws(Failure) in try timestamp(text) },
            updatedBy: try dto.updatedBy.map { text throws(Failure) in try identifier(text, "updatedBy") },
            deletedAt: try dto.deletedAt.map { text throws(Failure) in try timestamp(text) },
            deletedBy: try dto.deletedBy.map { text throws(Failure) in try identifier(text, "deletedBy") }
        )
    }

    static func settlement(_ dto: GroupSettlementDTO, groupID: GroupID, currency: CurrencyCode) throws(Failure) -> Settlement {
        Settlement(
            id: try identifier(dto.id, "settlement.id"), groupID: groupID, fromID: try identifier(dto.fromId, "fromId"),
            toID: try identifier(dto.toId, "toId"), amount: Money(minorUnits: Int64(dto.amount), currency: currency),
            date: try timestamp(dto.date), recordedBy: try identifier(dto.recordedBy, "recordedBy"),
            provider: dto.provider.flatMap(PaymentProviderKind.init(rawValue:)),
            attemptID: try dto.attemptId.map { text throws(Failure) in try identifier(text, "attemptId") },
            confirmedAt: try dto.confirmedAt.map { text throws(Failure) in try timestamp(text) },
            confirmedBy: try dto.confirmedBy.map { text throws(Failure) in try identifier(text, "confirmedBy") }
        )
    }

    static func attempt(_ dto: GroupAttemptDTO, groupID: GroupID, currency: CurrencyCode) throws(Failure) -> PaymentAttempt {
        guard let state = PaymentAttemptState(rawValue: dto.state), let provider = PaymentProviderKind(rawValue: dto.provider) else {
            throw .malformed("attempt.state")
        }
        let history = try dto.history.map { entry throws(Failure) in
            guard let state = PaymentAttemptState(rawValue: entry.state) else { throw .malformed("attempt.history") }
            return PaymentAttemptTransition(state: state, actorID: try identifier(entry.actorId, "actorId"), date: try timestamp(entry.at),
                                            note: entry.note)
        }
        return PaymentAttempt(
            id: try identifier(dto.id, "attempt.id"), groupID: groupID, payerID: try identifier(dto.payerId, "payerId"),
            recipientID: try identifier(dto.recipientId, "recipientId"),
            destinationID: try dto.destinationId.map { text throws(Failure) in try identifier(text, "destinationId") }, provider: provider,
            amount: Money(minorUnits: Int64(dto.amount), currency: currency), memo: dto.memo, state: state, history: history,
            externalReference: dto.externalReference,
            settlementID: try dto.settlementId.map { text throws(Failure) in try identifier(text, "settlementId") }
        )
    }

    // MARK: - Destinations

    static func destination(_ dto: DestinationDTO, owner: MemberID) -> PaymentDestination? {
        guard let id = PaymentDestinationID(string: dto.id), let provider = PaymentProviderKind(rawValue: dto.provider) else { return nil }
        let value: DestinationValue
        switch dto.value.kind {
        case "phone": value = .phone(dto.value.value)
        case "email": value = .email(dto.value.value)
        case "username": value = .username(dto.value.value)
        case "instructions": value = .instructions(dto.value.value)
        case "link":
            guard let url = URL(string: dto.value.value), ExternalURLPolicy.isAllowed(url, for: provider) else { return nil }
            value = .link(url)
        default: return nil
        }
        // Defence in depth: never keep a link the app itself wouldn't open.
        let link = dto.link.flatMap(URL.init(string:)).flatMap { ExternalURLPolicy.isAllowed($0, for: provider) ? $0 : nil }
        let created = dto.createdAt.flatMap { RemoteRoomMapper.timestamp($0) } ?? .distantPast
        return PaymentDestination(id: id, ownerID: owner, provider: provider, label: dto.label, value: value, link: link,
                                  isPreferred: dto.isPreferred, isEnabled: dto.isEnabled, createdAt: created,
                                  updatedAt: dto.updatedAt.flatMap { RemoteRoomMapper.timestamp($0) })
    }

    static func destinationRequest(_ destination: PaymentDestination) -> DestinationRequest {
        let value: DestinationValueDTO = switch destination.value {
        case .phone(let text): DestinationValueDTO(kind: "phone", value: text)
        case .email(let text): DestinationValueDTO(kind: "email", value: text)
        case .username(let text): DestinationValueDTO(kind: "username", value: text)
        case .link(let url): DestinationValueDTO(kind: "link", value: url.absoluteString)
        case .instructions(let text): DestinationValueDTO(kind: "instructions", value: text)
        }
        return DestinationRequest(provider: destination.provider.rawValue, value: value, link: destination.link?.absoluteString,
                                  label: destination.label, isEnabled: destination.isEnabled, isPreferred: destination.isPreferred)
    }

    // MARK: - Balance verification (§9.3)

    /// Whether the app's own calculation of the mapped records matches the server's balances:
    /// every net position (confirmed and available) and every planned payment.
    static func balancesAgree(_ snapshot: LedgerSnapshot, server: GroupBalancesDTO) -> Bool {
        guard let group = snapshot.groups.first else { return false }
        let plan = SettlementPlanner.plan(for: group, expenses: snapshot.expenses(in: group.id), settlements: snapshot.settlements(in: group.id),
                                          attempts: snapshot.attempts(in: group.id))
        let confirmed = Dictionary(uniqueKeysWithValues: plan.confirmedNets.map { (id($0.key), Int($0.value.minorUnits)) })
        let available = Dictionary(uniqueKeysWithValues: plan.availableNets.map { (id($0.key), Int($0.value.minorUnits)) })
        let payments = plan.payments.map { PlannedPaymentDTO(payerId: id($0.payerID), recipientId: id($0.recipientID), amount: Int($0.amount.minorUnits)) }
        return confirmed == server.confirmedNets && available == server.availableNets && payments == server.payments
            && plan.directPaymentCount == server.directPaymentCount && plan.simplifiedPaymentCount == server.simplifiedPaymentCount
    }

    // MARK: - Change pages

    /// Applies a page of changes to the last confirmed snapshot, or `nil` when the page can't be
    /// applied safely (an expired cursor or a gap): the caller then fetches a full snapshot.
    static func applying(_ changes: GroupChangesDTO, to base: GroupSnapshotDTO) -> GroupSnapshotDTO? {
        guard !changes.cursorExpired, changes.after == base.cursor, changes.cursor >= base.cursor,
              let header = changes.group, let viewer = changes.viewer, let members = changes.members, let balances = changes.balances,
              let events = changes.events else { return nil }
        let sequences = events.map(\.sequence)
        guard sequences == Array((base.cursor + 1)..<(base.cursor + 1 + events.count)), base.cursor + events.count == changes.cursor else { return nil }
        func upsert<T>(_ items: [T], into list: [T], id: (T) -> String) -> [T] {
            var result = list
            for item in items {
                if let index = result.firstIndex(where: { id($0) == id(item) }) { result[index] = item } else { result.append(item) }
            }
            return result
        }
        return GroupSnapshotDTO(
            schemaVersion: changes.schemaVersion, serverTime: changes.serverTime, revision: changes.revision, cursor: changes.cursor,
            group: header, viewer: viewer, members: members,
            expenses: upsert(changes.expenses ?? [], into: base.expenses, id: \.id),
            settlements: upsert(changes.settlements ?? [], into: base.settlements, id: \.id),
            attempts: upsert(changes.attempts ?? [], into: base.attempts, id: \.id),
            balances: balances,
            receipts: upsert(changes.receipts ?? [], into: base.receipts ?? [], id: \.id),
            events: base.events + events, eventsComplete: base.eventsComplete
        )
    }

    // MARK: - Commands

    /// How a command must travel.
    nonisolated struct WireCommand: Sendable {
        let type: String
        let payload: JSONValue
        /// Refused against a stale group revision (membership, ownership, group settings).
        let isRevisionStrict: Bool
        /// High-consequence: never queued offline; the person waits for the server's answer (§7.4).
        let requiresLiveResponse: Bool
        /// What a new entity will be called, so the result can name it before the server answers.
        var newMemberID: MemberID?
        var newAttemptID: PaymentAttemptID?
    }

    static func command(_ command: LedgerCommand, in snapshot: LedgerSnapshot) throws(Failure) -> WireCommand {
        switch command {
        case .updateGroup(_, let draft):
            let payload: JSONValue = [
                "name": .string(draft.name), "details": draft.details.isEmpty ? .null : .string(draft.details),
                "symbol": .string(draft.symbolName), "currency": .string(draft.currency.rawValue),
            ]
            return WireCommand(type: "updateGroup", payload: payload, isRevisionStrict: true, requiresLiveResponse: false)
        case .setSimplification(_, let enabled):
            return WireCommand(type: "setSimplification", payload: ["enabled": .bool(enabled)], isRevisionStrict: true, requiresLiveResponse: false)
        case .addMember(_, let draft):
            let memberID = MemberID()
            var command = WireCommand(type: "addSeat", payload: [
                "memberId": .string(id(memberID)), "displayName": .string(draft.displayName),
                "handle": draft.handle.isEmpty ? .null : .string(draft.handle),
            ], isRevisionStrict: true, requiresLiveResponse: false)
            command.newMemberID = memberID
            return command
        case .removeMember(_, let memberID):
            return WireCommand(type: "removeMember", payload: ["memberId": .string(id(memberID))], isRevisionStrict: true, requiresLiveResponse: true)
        case .addExpense(let expense):
            return WireCommand(type: "addExpense", payload: expensePayload(expense, previous: nil), isRevisionStrict: false, requiresLiveResponse: false)
        case .updateExpense(let expense):
            let previous = snapshot.expense(expense.id)
            return WireCommand(type: "updateExpense", payload: expensePayload(expense, previous: previous), isRevisionStrict: false,
                               requiresLiveResponse: false)
        case .deleteExpense(let expenseID):
            return WireCommand(type: "deleteExpense", payload: ["expenseId": .string(id(expenseID))], isRevisionStrict: false, requiresLiveResponse: false)
        case .restoreExpense(let expenseID):
            return WireCommand(type: "restoreExpense", payload: ["expenseId": .string(id(expenseID))], isRevisionStrict: false, requiresLiveResponse: false)
        case .startPayment(let request):
            let attemptID = PaymentAttemptID()
            let group = snapshot.group(request.groupID)?.name ?? ""
            var command = WireCommand(type: "startPayment", payload: [
                "attemptId": .string(id(attemptID)), "recipientId": .string(id(request.recipientID)),
                "amount": .int(Int(request.amount.minorUnits)), "provider": .string(request.provider.rawValue),
                "destinationId": request.destinationID.map { .string(id($0)) } ?? .null,
                "memo": .string(String(localized: "Square Up · \(group) · \(PaymentAttempt.reference(for: attemptID))")),
            ], isRevisionStrict: false, requiresLiveResponse: false)
            command.newAttemptID = attemptID
            return command
        case .advancePayment(let attemptID, let action):
            var payload: [String: JSONValue] = ["attemptId": .string(id(attemptID))]
            let live: Bool
            switch action {
            case .openHandoff:
                payload["action"] = "openHandoff"
                live = false
            case .reportSent(let reference):
                payload["action"] = "reportSent"
                if let reference, !reference.isEmpty { payload["externalReference"] = .string(reference) }
                live = false
            case .confirm:
                payload["action"] = "confirm"
                live = true
            case .reject(let reason):
                payload["action"] = "reject"
                if let reason { payload["reason"] = .string(reason) }
                live = true
            case .dispute(let reason):
                payload["action"] = "dispute"
                if let reason { payload["reason"] = .string(reason) }
                live = true
            case .cancel:
                payload["action"] = "cancel"
                live = false
            }
            return WireCommand(type: "advancePayment", payload: .object(payload), isRevisionStrict: false, requiresLiveResponse: live)
        default:
            throw .unsupportedCommand
        }
    }

    static func expensePayload(_ expense: Expense, previous: Expense?, receipt: ReceiptAllocationSnapshot? = nil) -> JSONValue {
        func shares(_ list: [Share]) -> JSONValue {
            .array(list.map { ["memberId": .string(id($0.memberID)), "amount": .int(Int($0.amount.minorUnits))] })
        }
        let body: [String: JSONValue] = [
            "id": .string(id(expense.id)), "title": .string(expense.title), "merchant": expense.merchant.map(JSONValue.string) ?? .null,
            "date": .string(iso(expense.date)), "total": .int(Int(expense.total.minorUnits)), "currency": .string(expense.currency.rawValue),
            "category": .string(expense.category.rawValue), "splitMethod": .string(expense.splitMethod.rawValue),
            "payments": shares(expense.payments), "allocations": shares(expense.allocations), "note": expense.note.map(JSONValue.string) ?? .null,
        ]
        var payload: [String: JSONValue] = ["expense": .object(body)]
        if let previous {
            payload["expenseId"] = .string(id(expense.id))
            payload["expectedExpenseRevision"] = .int(previous.revision)
        }
        switch expense.splitInput {
        case .equal(let people):
            payload["split"] = ["method": "equal", "participants": .array(people.map { .string(id($0)) })]
        case .shares(let weights):
            payload["split"] = ["method": "shares", "weights": .array(weights.map { ["memberId": .string(id($0.memberID)), "weight": .int($0.weight)] })]
        case .percentage(let percentages):
            payload["split"] = ["method": "percentage", "percentages": .array(percentages.map {
                ["memberId": .string(id($0.memberID)), "percent": .string(percentText($0.percent))]
            })]
        case nil:
            break
        }
        if let receipt, let encoded = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Self.receipt(receipt))) {
            payload["receipt"] = encoded
        }
        return .object(payload)
    }

    /// A percentage as a plain decimal string ("33.34"), at most four fraction digits.
    static func percentText(_ value: Decimal) -> String {
        let rounded = value.rounded(scale: 4, mode: .plain)
        return NSDecimalNumber(decimal: rounded).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}
