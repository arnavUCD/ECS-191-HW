import Foundation

/// A confirmed payment that happened *outside* Square Up.
///
/// Square Up never moves money. A `Settlement` exists only once a payment is confirmed (by the
/// recipient, or for legacy/manual records by the person recording it). Transient states live
/// on `PaymentAttempt`.
nonisolated struct Settlement: Identifiable, Hashable, Sendable {
    let id: SettlementID
    let groupID: GroupID
    /// The person who paid.
    let fromID: MemberID
    /// The person who received the payment.
    let toID: MemberID
    let amount: Money
    var date: Date
    var note: String?
    let recordedBy: MemberID
    /// How the money moved, when known.
    var provider: PaymentProviderKind?
    /// The attempt this settlement finalises. At most one settlement per attempt.
    var attemptID: PaymentAttemptID?
    var confirmedAt: Date?
    var confirmedBy: MemberID?

    init(
        id: SettlementID = SettlementID(),
        groupID: GroupID,
        fromID: MemberID,
        toID: MemberID,
        amount: Money,
        date: Date,
        note: String? = nil,
        recordedBy: MemberID,
        provider: PaymentProviderKind? = nil,
        attemptID: PaymentAttemptID? = nil,
        confirmedAt: Date? = nil,
        confirmedBy: MemberID? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.fromID = fromID
        self.toID = toID
        self.amount = amount
        self.date = date
        self.note = note
        self.recordedBy = recordedBy
        self.provider = provider
        self.attemptID = attemptID
        self.confirmedAt = confirmedAt
        self.confirmedBy = confirmedBy
    }
}
