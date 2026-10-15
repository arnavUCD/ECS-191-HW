import Foundation

/// The payment services Square Up can represent. Support means Square Up can describe and hand
/// off to the method safely — not that it has a financial partnership with the provider.
nonisolated enum PaymentProviderKind: String, Codable, Sendable, CaseIterable {
    case appleCash
    case paypal
    case cashApp
    case zelle
    case venmo
    case cash
    case other
}

/// Where a recipient accepts money. Values are normalised by `PaymentDestinationValidator`.
nonisolated enum DestinationValue: Hashable, Codable, Sendable {
    /// E.164 phone number, e.g. "+15305550142".
    case phone(String)
    /// Lower-cased email address.
    case email(String)
    /// Provider username without its sigil (PayPal.Me name, Venmo username, Cash App cashtag).
    case username(String)
    /// A validated, provider-allowlisted HTTPS link supplied by the recipient.
    case link(URL)
    /// Free text for cash or other methods ("Cash in person").
    case instructions(String)
}

/// A way one member accepts payment. Sensitive: never logged, masked in general views.
nonisolated struct PaymentDestination: Identifiable, Hashable, Codable, Sendable {
    let id: PaymentDestinationID
    let ownerID: MemberID
    var provider: PaymentProviderKind
    /// Optional recipient-chosen label ("Personal", "Venmo for rent").
    var label: String?
    var value: DestinationValue
    /// Optional official link alongside the main value: a Cash App payment link or a Zelle QR link.
    var link: URL?
    var isPreferred: Bool
    var isEnabled: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: PaymentDestinationID = PaymentDestinationID(),
        ownerID: MemberID,
        provider: PaymentProviderKind,
        label: String? = nil,
        value: DestinationValue,
        link: URL? = nil,
        isPreferred: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.provider = provider
        self.label = label
        self.value = value
        self.link = link
        self.isPreferred = isPreferred
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// Lifecycle of one attempt to pay one obligation (milestone 2 §13).
nonisolated enum PaymentAttemptState: String, Codable, Sendable, CaseIterable {
    /// A draft exists; balances are unchanged.
    case methodSelected
    /// An external destination was opened; balances are unchanged.
    case handoffOpened
    /// The payer says it was sent. Reserved out of new suggestions; not yet in the ledger.
    case reportedSent
    /// The recipient acknowledged receipt. A `Settlement` exists.
    case confirmed
    /// The recipient says the money did not arrive. The obligation is payable again.
    case rejected
    /// Payer and recipient disagree. Still reserved; nobody is described as settled.
    case disputed
    /// Closed without financial effect.
    case cancelled

    /// Draft states: nothing reported yet.
    var isDraft: Bool { self == .methodSelected || self == .handoffOpened }
    /// States that hold the amount out of the available-to-settle plan.
    var reservesObligation: Bool { self == .reportedSent || self == .disputed }
    var isTerminal: Bool { self == .confirmed || self == .rejected || self == .cancelled }
}

nonisolated enum PaymentCancelReason: String, Codable, Sendable {
    /// The payer cancelled.
    case payerCancelled
    /// A newer attempt for the same obligation replaced this draft.
    case superseded
}

/// What someone did to an attempt.
nonisolated enum PaymentAttemptAction: Equatable, Sendable {
    case openHandoff
    case reportSent(externalReference: String?)
    case confirm
    case reject(reason: String?)
    case dispute(reason: String?)
    case cancel(PaymentCancelReason)
}

/// One recorded state change: who, when, and why.
nonisolated struct PaymentAttemptTransition: Hashable, Codable, Sendable {
    let state: PaymentAttemptState
    let actorID: MemberID
    let date: Date
    var note: String?
}

/// One attempt to pay one obligation. Never a confirmed payment by itself — that is `Settlement`.
nonisolated struct PaymentAttempt: Identifiable, Hashable, Codable, Sendable {
    let id: PaymentAttemptID
    let groupID: GroupID
    let payerID: MemberID
    let recipientID: MemberID
    var destinationID: PaymentDestinationID?
    var provider: PaymentProviderKind
    let amount: Money
    /// User-visible memo, e.g. "Square Up · Weekend Trip · SU-4821".
    let memo: String
    var state: PaymentAttemptState
    var history: [PaymentAttemptTransition]
    /// A reference the payer typed (e.g. a confirmation number). Never verified by Square Up.
    var externalReference: String?
    var settlementID: SettlementID?

    /// Stable key for the obligation this attempt pays, independent of plan ordering.
    var obligationKey: String { Self.obligationKey(groupID: groupID, payerID: payerID, recipientID: recipientID) }

    var createdAt: Date { history.first?.date ?? .distantPast }

    /// Short human reference shown in memos and confirmations, derived from the identifier.
    var reference: String { Self.reference(for: id) }

    func date(of state: PaymentAttemptState) -> Date? {
        history.last { $0.state == state }?.date
    }

    func actor(of state: PaymentAttemptState) -> MemberID? {
        history.last { $0.state == state }?.actorID
    }

    static func obligationKey(groupID: GroupID, payerID: MemberID, recipientID: MemberID) -> String {
        "\(groupID.rawValue.uuidString)|\(payerID.rawValue.uuidString)|\(recipientID.rawValue.uuidString)"
    }

    static func reference(for id: PaymentAttemptID) -> String {
        "SU-" + String(id.stableBucket(count: 9000) + 1000)
    }
}

/// What the payer asks to start paying.
nonisolated struct PaymentRequest: Equatable, Sendable {
    let groupID: GroupID
    let payerID: MemberID
    let recipientID: MemberID
    let amount: Money
    let provider: PaymentProviderKind
    let destinationID: PaymentDestinationID?
}
