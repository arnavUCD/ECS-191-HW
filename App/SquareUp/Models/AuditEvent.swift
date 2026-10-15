import Foundation

nonisolated enum GroupField: String, Codable, Sendable, CaseIterable {
    case name, details, symbol, currency
}

nonisolated enum ExpenseField: String, Codable, Sendable, CaseIterable {
    case title, amount, date, category, payers, split, participants
}

/// Who paid whom, how much, and how — shared by every payment event.
nonisolated struct PaymentEventInfo: Hashable, Codable, Sendable {
    let attemptID: PaymentAttemptID
    let payerID: MemberID
    let recipientID: MemberID
    let amount: Money
    let provider: PaymentProviderKind

    init(_ attempt: PaymentAttempt) {
        attemptID = attempt.id
        payerID = attempt.payerID
        recipientID = attempt.recipientID
        amount = attempt.amount
        provider = attempt.provider
    }

    init(attemptID: PaymentAttemptID, payerID: MemberID, recipientID: MemberID, amount: Money, provider: PaymentProviderKind) {
        self.attemptID = attemptID
        self.payerID = payerID
        self.recipientID = recipientID
        self.amount = amount
        self.provider = provider
    }
}

/// An append-only record of a financial or membership change (milestone 2 §14 "Audit event").
///
/// Edits and deletions carry the previous revision so history stays explainable while only the
/// current, non-deleted revision affects balances.
nonisolated struct AuditEvent: Identifiable, Hashable, Codable, Sendable {
    nonisolated enum Kind: Hashable, Codable, Sendable {
        case groupCreated(name: String)
        case groupEdited(fields: [GroupField])
        case memberAdded(MemberID)
        case memberRemoved(MemberID)
        case simplificationChanged(enabled: Bool)
        case expenseCreated(ExpenseID, title: String, total: Money)
        case expenseEdited(ExpenseID, title: String, fields: [ExpenseField], previous: ExpenseRevision, revision: Int)
        case expenseDeleted(ExpenseID, snapshot: ExpenseRevision)
        case expenseRestored(ExpenseID, title: String)
        case settlementRecorded(SettlementID, fromID: MemberID, toID: MemberID, amount: Money)
        case paymentStarted(PaymentEventInfo)
        case paymentReported(PaymentEventInfo)
        case paymentConfirmed(PaymentEventInfo, settlementID: SettlementID)
        case paymentRejected(PaymentEventInfo, reason: String?)
        case paymentDisputed(PaymentEventInfo, reason: String?)
        case paymentCancelled(PaymentEventInfo, reason: PaymentCancelReason)
        /// Milestone 3: a Live Receipt Room opened for claiming.
        case receiptRoomOpened(ReceiptRoomID, title: String, participantCount: Int)
        /// Milestone 3: a room became an itemized expense (the expense has its own `expenseCreated`).
        case receiptRoomFinalized(ReceiptRoomID, expenseID: ExpenseID, title: String)
        case receiptRoomCancelled(ReceiptRoomID, title: String)
        // Milestone 7: shared groups (recorded by the server).
        /// A local group was shared; its earlier history came with it.
        case groupPublished(name: String)
        case groupArchived
        /// The owner created an invitation, for a waiting seat or for someone new.
        case memberInvited(seat: MemberID?)
        case memberJoined(MemberID)
        case memberLeft(MemberID)
        case ownershipTransferred(from: MemberID, to: MemberID)
        /// A finalized shared Live Receipt Room became this group's expense (once).
        case receiptRoomAdopted(ReceiptRoomID, expenseID: ExpenseID, title: String)
        /// The payer opened a payment app or copied details. Proves nothing about payment.
        case paymentHandoffOpened(PaymentEventInfo)
    }

    nonisolated enum Category: Hashable, Sendable {
        case group, expense, payment
    }

    let id: AuditEventID
    let groupID: GroupID
    let actorID: MemberID
    let date: Date
    /// Monotonic order within the ledger; breaks ties when events share a timestamp.
    let sequence: Int
    let kind: Kind

    var category: Category {
        switch kind {
        case .groupCreated, .groupEdited, .memberAdded, .memberRemoved, .simplificationChanged,
             .groupPublished, .groupArchived, .memberInvited, .memberJoined, .memberLeft, .ownershipTransferred: .group
        case .expenseCreated, .expenseEdited, .expenseDeleted, .expenseRestored,
             .receiptRoomOpened, .receiptRoomFinalized, .receiptRoomCancelled, .receiptRoomAdopted: .expense
        case .settlementRecorded, .paymentStarted, .paymentReported, .paymentConfirmed,
             .paymentRejected, .paymentDisputed, .paymentCancelled, .paymentHandoffOpened: .payment
        }
    }
}
