import Foundation

/// Conversions between SwiftData records and domain values.
///
/// Unknown raw values (e.g. a category written by a newer build) degrade to safe defaults
/// instead of crashing.
extension MemberRecord {
    convenience init(_ member: Member, isCurrentUser: Bool) {
        self.init(id: member.id.rawValue, displayName: member.displayName, handle: member.handle, isCurrentUser: isCurrentUser)
    }

    func update(from member: Member) {
        displayName = member.displayName
        handle = member.handle
    }

    var domain: Member {
        Member(id: MemberID(id), displayName: displayName, handle: handle)
    }
}

extension GroupRecord {
    convenience init(_ group: ExpenseGroup) {
        self.init(
            id: group.id.rawValue, name: group.name, kind: LegacyRecords.personalKind, currencyCode: group.currency.rawValue,
            symbolName: group.symbolName, memberships: [], budget: nil, createdAt: group.createdAt
        )
        update(from: group)
    }

    /// `kind` and `budget` are legacy storage fields: personal groups always store "personal" and no
    /// budget, and an edit never rewrites them.
    func update(from group: ExpenseGroup) {
        name = group.name
        currencyCode = group.currency.rawValue
        symbolName = group.symbolName
        memberships = group.memberships.map {
            MembershipValue(memberID: $0.memberID.rawValue, roles: [LegacyRecords.memberRole], removedAt: $0.removedAt)
        }
        details = group.details
        simplifiesDebts = group.simplifiesDebts
    }

    var domain: ExpenseGroup {
        ExpenseGroup(
            id: GroupID(id),
            name: name,
            currency: CurrencyCode(currencyCode),
            symbolName: symbolName,
            memberships: memberships.map { Membership(memberID: MemberID($0.memberID), removedAt: $0.removedAt) },
            createdAt: createdAt,
            details: details,
            simplifiesDebts: simplifiesDebts
        )
    }
}

extension ExpenseRecord {
    convenience init(_ expense: Expense) {
        self.init(
            id: expense.id.rawValue, title: expense.title, merchant: expense.merchant, date: expense.date,
            totalMinorUnits: expense.total.minorUnits, currencyCode: expense.currency.rawValue,
            category: expense.category.rawValue, splitMethod: expense.splitMethod.rawValue,
            payments: [], allocations: [], funding: nil, note: expense.note,
            createdByID: expense.createdBy.rawValue, createdAt: expense.createdAt
        )
        update(from: expense)
    }

    func update(from expense: Expense) {
        title = expense.title
        merchant = expense.merchant
        date = expense.date
        totalMinorUnits = expense.total.minorUnits
        currencyCode = expense.currency.rawValue
        category = expense.category.rawValue
        splitMethod = expense.splitMethod.rawValue
        payments = expense.payments.map(ShareValue.init)
        allocations = expense.allocations.map(ShareValue.init)
        note = expense.note
        revision = expense.revision
        updatedAt = expense.updatedAt
        updatedByID = expense.updatedBy?.rawValue
        deletedAt = expense.deletedAt
        deletedByID = expense.deletedBy?.rawValue
    }

    func domain(groupID: GroupID) -> Expense {
        let currency = CurrencyCode(currencyCode)
        return Expense(
            id: ExpenseID(id),
            groupID: groupID,
            title: title,
            merchant: merchant,
            date: date,
            total: Money(minorUnits: totalMinorUnits, currency: currency),
            category: ExpenseCategory(rawValue: category) ?? .other,
            splitMethod: SplitMethod(rawValue: splitMethod) ?? .exact,
            payments: payments.map { $0.domain(currency) },
            allocations: allocations.map { $0.domain(currency) },
            note: note,
            createdBy: MemberID(createdByID),
            createdAt: createdAt,
            revision: revision,
            updatedAt: updatedAt,
            updatedBy: updatedByID.map(MemberID.init),
            deletedAt: deletedAt,
            deletedBy: deletedByID.map(MemberID.init)
        )
    }
}

extension SettlementRecord {
    convenience init(_ settlement: Settlement) {
        self.init(
            id: settlement.id.rawValue, fromID: settlement.fromID.rawValue, toID: settlement.toID.rawValue,
            amountMinorUnits: settlement.amount.minorUnits, currencyCode: settlement.amount.currency.rawValue,
            date: settlement.date, note: settlement.note, recordedByID: settlement.recordedBy.rawValue
        )
        update(from: settlement)
    }

    func update(from settlement: Settlement) {
        amountMinorUnits = settlement.amount.minorUnits
        currencyCode = settlement.amount.currency.rawValue
        date = settlement.date
        note = settlement.note
        provider = settlement.provider?.rawValue
        attemptID = settlement.attemptID?.rawValue
        confirmedAt = settlement.confirmedAt
        confirmedByID = settlement.confirmedBy?.rawValue
    }

    func domain(groupID: GroupID) -> Settlement {
        Settlement(
            id: SettlementID(id),
            groupID: groupID,
            fromID: MemberID(fromID),
            toID: MemberID(toID),
            amount: Money(minorUnits: amountMinorUnits, currency: CurrencyCode(currencyCode)),
            date: date,
            note: note,
            recordedBy: MemberID(recordedByID),
            provider: provider.flatMap(PaymentProviderKind.init(rawValue:)),
            attemptID: attemptID.map(PaymentAttemptID.init),
            confirmedAt: confirmedAt,
            confirmedBy: confirmedByID.map(MemberID.init)
        )
    }
}

/// JSON coding for payload records. Money encodes as integer minor units, so payloads never
/// pass amounts through floating point.
nonisolated enum PayloadCoding {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

nonisolated extension ShareValue {
    init(_ share: Share) {
        self.init(memberID: share.memberID.rawValue, minorUnits: share.amount.minorUnits)
    }

    func domain(_ currency: CurrencyCode) -> Share {
        Share(MemberID(memberID), Money(minorUnits: minorUnits, currency: currency))
    }
}
