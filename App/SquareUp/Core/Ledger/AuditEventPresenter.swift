import Foundation

/// Human-language description of an audit event (milestone 2 §7: actor, amount, method, time).
nonisolated struct AuditEventDescription: Hashable, Sendable {
    enum Tone: Hashable, Sendable {
        case neutral, positive, warning, negative, informational
    }

    let title: String
    let detail: String?
    let symbolName: String
    let tone: Tone
    let amount: Money?
}

nonisolated enum AuditEventPresenter {
    /// Events already represented by a ledger row (the expense or settlement itself) are not
    /// repeated in feeds.
    static func isShownInFeed(_ event: AuditEvent) -> Bool {
        switch event.kind {
        case .expenseCreated, .settlementRecorded, .paymentConfirmed, .receiptRoomFinalized, .receiptRoomAdopted: false
        default: true
        }
    }

    static func describe(
        _ event: AuditEvent,
        members: [MemberID: Member],
        currentUserID: MemberID,
        locale: Locale = .autoupdatingCurrent
    ) -> AuditEventDescription {
        let labels = PersonIdentity.shortLabels(for: Array(members.values))
        func name(_ id: MemberID, capitalized: Bool = true) -> String {
            if id == currentUserID { return capitalized ? String(localized: "You") : String(localized: "you") }
            return labels[id] ?? members[id]?.displayName ?? String(localized: "Someone")
        }
        let actor = name(event.actorID)
        let money = { (value: Money) in MoneyFormatting.string(value, locale: locale) }

        switch event.kind {
        case .groupCreated(let groupName):
            return .init(title: String(localized: "\(actor) created \(groupName)"), detail: nil,
                         symbolName: "sparkles", tone: .neutral, amount: nil)
        case .groupEdited(let fields):
            let list = fields.map(fieldLabel).formatted(.list(type: .and))
            return .init(title: String(localized: "\(actor) edited the group"), detail: String(localized: "Changed \(list)"),
                         symbolName: "pencil", tone: .neutral, amount: nil)
        case .memberAdded(let id):
            return .init(title: String(localized: "\(actor) added \(name(id, capitalized: false))"), detail: nil,
                         symbolName: "person.badge.plus", tone: .neutral, amount: nil)
        case .memberRemoved(let id):
            return .init(title: String(localized: "\(actor) removed \(name(id, capitalized: false))"),
                         detail: String(localized: "Past expenses and payments are kept."),
                         symbolName: "person.badge.minus", tone: .neutral, amount: nil)
        case .simplificationChanged(let enabled):
            return .init(title: enabled ? String(localized: "\(actor) turned on simplified payments")
                : String(localized: "\(actor) turned off simplified payments"),
                detail: String(localized: "Changes who pays whom, not what anyone owes."),
                symbolName: "arrow.triangle.branch", tone: .neutral, amount: nil)
        case .expenseCreated(_, let title, let total):
            return .init(title: String(localized: "\(actor) added \(title)"), detail: nil,
                         symbolName: "plus.circle", tone: .neutral, amount: total)
        case .expenseEdited(_, let title, let fields, let previous, let revision):
            let list = fields.map(fieldLabel).formatted(.list(type: .and))
            return .init(title: String(localized: "\(actor) edited \(title)"),
                         detail: String(localized: "Changed \(list) · revision \(revision) (was \(money(previous.total)))"),
                         symbolName: "pencil.circle", tone: .informational, amount: nil)
        case .expenseDeleted(_, let snapshot):
            return .init(title: String(localized: "\(actor) deleted \(snapshot.title)"),
                         detail: String(localized: "No longer affects balances. The record is kept."),
                         symbolName: "trash", tone: .negative, amount: snapshot.total)
        case .expenseRestored(_, let title):
            return .init(title: String(localized: "\(actor) restored \(title)"), detail: nil,
                         symbolName: "arrow.uturn.backward.circle", tone: .informational, amount: nil)
        case .settlementRecorded(_, let fromID, let toID, let amount) where event.actorID == toID && fromID != toID:
            // "Mark as settled" in a shared group: the person owed recorded it themselves.
            return .init(title: String(localized: "\(name(toID)) marked \(name(fromID, capitalized: false)) as settled"),
                         detail: String(localized: "Paid outside Square Up, or not needed back"), symbolName: "checkmark.circle",
                         tone: .positive, amount: amount)
        case .settlementRecorded(_, let fromID, let toID, let amount):
            return .init(title: String(localized: "\(name(fromID)) paid \(name(toID, capitalized: false))"),
                         detail: String(localized: "Recorded payment"), symbolName: "arrow.left.arrow.right",
                         tone: .positive, amount: amount)
        case .paymentStarted(let info):
            return .init(title: String(localized: "\(name(info.payerID)) started paying \(name(info.recipientID, capitalized: false))"),
                         detail: String(localized: "Using \(info.provider.displayName) · not paid yet"),
                         symbolName: "arrow.up.forward.app", tone: .neutral, amount: info.amount)
        case .paymentReported(let info):
            return .init(title: String(localized: "\(name(info.payerID)) reported paying \(name(info.recipientID, capitalized: false))"),
                         detail: String(localized: "\(info.provider.displayName) · awaiting \(name(info.recipientID, capitalized: false)) to confirm"),
                         symbolName: "hourglass", tone: .warning, amount: info.amount)
        case .paymentConfirmed(let info, _):
            return .init(title: String(localized: "\(name(info.recipientID)) confirmed receiving \(money(info.amount))"),
                         detail: String(localized: "From \(name(info.payerID, capitalized: false)) via \(info.provider.displayName)"),
                         symbolName: "checkmark.seal.fill", tone: .positive, amount: info.amount)
        case .paymentRejected(let info, let reason):
            return .init(title: String(localized: "\(name(info.recipientID)) didn't receive \(name(info.payerID, capitalized: false))'s payment"),
                         detail: reason ?? String(localized: "The amount is owed again."),
                         symbolName: "xmark.octagon", tone: .negative, amount: info.amount)
        case .paymentDisputed(let info, let reason):
            return .init(title: String(localized: "Payment from \(name(info.payerID, capitalized: false)) is disputed"),
                         detail: reason ?? String(localized: "Neither person is marked as settled until it's resolved."),
                         symbolName: "exclamationmark.bubble", tone: .warning, amount: info.amount)
        case .paymentCancelled(let info, let reason):
            return .init(title: reason == .superseded
                ? String(localized: "\(name(info.payerID)) switched payment method")
                : String(localized: "\(name(info.payerID)) cancelled a payment to \(name(info.recipientID, capitalized: false))"),
                detail: String(localized: "No money was recorded."),
                symbolName: "xmark.circle", tone: .neutral, amount: info.amount)
        case .receiptRoomOpened(_, let title, let count):
            return .init(title: String(localized: "\(actor) opened a receipt room for \(title)"),
                         detail: Inflect.string("^[\(count) person](inflect: true) can claim items"),
                         symbolName: "list.bullet.rectangle.portrait", tone: .informational, amount: nil)
        case .receiptRoomFinalized(_, _, let title):
            return .init(title: String(localized: "\(actor) finalized the \(title) receipt"), detail: nil,
                         symbolName: "checkmark.rectangle.stack", tone: .positive, amount: nil)
        case .receiptRoomCancelled(_, let title):
            return .init(title: String(localized: "\(actor) closed the \(title) receipt room"),
                         detail: String(localized: "No expense was created."),
                         symbolName: "xmark.rectangle", tone: .neutral, amount: nil)
        case .groupPublished, .groupArchived, .memberInvited, .memberJoined, .memberLeft, .ownershipTransferred:
            return membershipDescription(event.kind, actor: actor) { name($0, capitalized: $1) }
        case .receiptRoomAdopted(_, _, let title):
            return .init(title: String(localized: "\(actor) saved the shared \(title) receipt"), detail: nil,
                         symbolName: "checkmark.rectangle.stack", tone: .positive, amount: nil)
        case .paymentHandoffOpened(let info):
            return .init(title: String(localized: "\(name(info.payerID)) opened \(info.provider.displayName) to pay \(name(info.recipientID, capitalized: false))"),
                         detail: String(localized: "Not paid yet · opening an app doesn't mean money was sent"),
                         symbolName: "arrow.up.forward.app", tone: .neutral, amount: info.amount)
        }
    }

    /// Shared-group membership events (milestone 7).
    private static func membershipDescription(_ kind: AuditEvent.Kind, actor: String,
                                              nameOf: (MemberID, Bool) -> String) -> AuditEventDescription {
        func name(_ id: MemberID, capitalized: Bool = true) -> String { nameOf(id, capitalized) }
        switch kind {
        case .groupPublished(let groupName):
            return .init(title: String(localized: "\(actor) shared \(groupName)"),
                         detail: String(localized: "Its earlier expenses and payments came with it."),
                         symbolName: "person.2.badge.gearshape", tone: .informational, amount: nil)
        case .groupArchived:
            return .init(title: String(localized: "\(actor) archived the group"),
                         detail: String(localized: "Nothing new can be added. History is kept."),
                         symbolName: "archivebox", tone: .neutral, amount: nil)
        case .memberInvited(let seat):
            return .init(title: seat.map { String(localized: "\(actor) invited \(name($0, capitalized: false))") }
                ?? String(localized: "\(actor) created an invitation"),
                detail: nil, symbolName: "envelope", tone: .neutral, amount: nil)
        case .memberJoined(let id):
            return .init(title: String(localized: "\(name(id)) joined"), detail: nil,
                         symbolName: "person.crop.circle.badge.checkmark", tone: .positive, amount: nil)
        case .memberLeft(let id):
            return .init(title: String(localized: "\(name(id)) left the group"),
                         detail: String(localized: "Past expenses and payments are kept."),
                         symbolName: "rectangle.portrait.and.arrow.right", tone: .neutral, amount: nil)
        case .ownershipTransferred(_, let to):
            return .init(title: String(localized: "\(actor) made \(name(to, capitalized: false)) the group's owner"),
                         detail: String(localized: "The owner manages the group's details and invitations."),
                         symbolName: "person.badge.key", tone: .neutral, amount: nil)
        default:
            return .init(title: actor, detail: nil, symbolName: "circle", tone: .neutral, amount: nil)
        }
    }

    static func fieldLabel(_ field: GroupField) -> String {
        switch field {
        case .name: String(localized: "name")
        case .details: String(localized: "description")
        case .symbol: String(localized: "icon")
        case .currency: String(localized: "currency")
        }
    }

    static func fieldLabel(_ field: ExpenseField) -> String {
        switch field {
        case .title: String(localized: "description")
        case .amount: String(localized: "amount")
        case .date: String(localized: "date")
        case .category: String(localized: "category")
        case .payers: String(localized: "who paid")
        case .split: String(localized: "split")
        case .participants: String(localized: "who shares it")
        }
    }
}

nonisolated extension PaymentProviderKind {
    var displayName: String {
        switch self {
        case .appleCash: String(localized: "Apple Cash")
        case .paypal: String(localized: "PayPal")
        case .cashApp: String(localized: "Cash App")
        case .zelle: String(localized: "Zelle")
        case .venmo: String(localized: "Venmo")
        case .cash: String(localized: "Cash")
        case .other: String(localized: "Other")
        }
    }
}
