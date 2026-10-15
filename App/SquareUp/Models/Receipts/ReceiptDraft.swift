import Foundation

/// The values a recognizer proposed for one line, kept for audit after edits.
nonisolated struct ItemProposal: Hashable, Codable, Sendable {
    let name: String
    let quantity: Int?
    let unitPrice: Money?
    let lineTotal: Money
}

/// One purchased line (milestone 3 §10.5).
///
/// `lineTotal` is signed: refunds and returns are negative and must be flagged `isRefund`.
/// A zero line is kept as a note and never allocated.
nonisolated struct ReceiptLineItem: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptItemID
    var name: ReceiptField<String>
    var quantity: Int?
    var unitPrice: Money?
    var lineTotal: ReceiptField<Money>
    var isRefund: Bool
    /// What recognition originally proposed; `nil` for lines a person added.
    var proposal: ItemProposal?

    init(
        id: ReceiptItemID = ReceiptItemID(), name: ReceiptField<String>, quantity: Int? = nil, unitPrice: Money? = nil,
        lineTotal: ReceiptField<Money>, isRefund: Bool = false, proposal: ItemProposal? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.lineTotal = lineTotal
        self.isRefund = isRefund
        self.proposal = proposal
    }

    var amount: Money { lineTotal.value }
    /// Zero-value lines are notes: kept, shown, never allocated.
    var isNote: Bool { amount.isZero }
    var isChargeable: Bool { !amount.isZero }
    var sourceRegionIDs: [ReceiptRegionID] { name.sourceRegionIDs + lineTotal.sourceRegionIDs }
    var attention: ReceiptAttention { max(name.attention, lineTotal.attention) }
}

nonisolated enum ReceiptChargeKind: String, Codable, Sendable, CaseIterable {
    case tax
    case tip
    case serviceCharge
    case fee
    case discount
    /// A documented, labelled difference the person chose to record explicitly.
    case adjustment

    /// Discounts are stored as negative amounts; everything except adjustments is positive.
    var sign: Int {
        switch self {
        case .discount: -1
        case .adjustment: 0
        case .tax, .tip, .serviceCharge, .fee: 1
        }
    }
}

/// A participant weight for share-based allocation.
nonisolated struct MemberWeight: Hashable, Codable, Sendable {
    let memberID: MemberID
    let weight: Int

    init(_ memberID: MemberID, _ weight: Int) {
        self.memberID = memberID
        self.weight = weight
    }
}

/// How an additional charge or discount is divided (milestone 3 §8.8).
nonisolated enum ChargeAllocation: Hashable, Codable, Sendable {
    /// In proportion to each person's item subtotal (default for tax, fees, and discounts).
    case proportional
    /// Equally among the listed people; `nil` means everyone who has items.
    case equal([MemberID]?)
    case shares([MemberWeight])
    /// Exact amounts that must add up to the charge.
    case exact([Share])
    /// The payer intentionally accepts the whole charge.
    case payer

    var kind: Kind {
        switch self {
        case .proportional: .proportional
        case .equal: .equal
        case .shares: .shares
        case .exact: .exact
        case .payer: .payer
        }
    }

    nonisolated enum Kind: String, Codable, Sendable, CaseIterable {
        case proportional, equal, shares, exact, payer
    }
}

/// Tax, tip, service charge, fee, discount, or adjustment (milestone 3 §10.6).
nonisolated struct ReceiptCharge: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptChargeID
    var kind: ReceiptChargeKind
    var label: String
    /// Signed: discounts negative, other charges positive, adjustments either.
    var amount: ReceiptField<Money>
    var allocation: ChargeAllocation

    init(
        id: ReceiptChargeID = ReceiptChargeID(), kind: ReceiptChargeKind, label: String, amount: ReceiptField<Money>,
        allocation: ChargeAllocation = .proportional
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.amount = amount
        self.allocation = allocation
    }

    var value: Money { amount.value }
}

/// Facts the structurer noticed that a person should know but that are not values to allocate.
nonisolated enum StructuringNote: Hashable, Codable, Sendable {
    /// "Tax included" lines: informational, already inside item prices.
    case taxIncluded(Money)
    /// A tip line with no amount written in.
    case blankTip
    /// More than one plausible total; the chosen one is flagged "Check this".
    case multipleTotals([Money])
    /// Symbols for more than one currency were found.
    case mixedCurrencies([CurrencyCode])
    /// No text was found on any page.
    case noText
    /// Text was found but no priced lines.
    case noPricedLines
}

nonisolated enum RecognitionProviderKind: String, Codable, Sendable {
    /// Vision OCR + the deterministic structurer (always available).
    case onDeviceDeterministic
    /// Vision OCR + optional Foundation Models proposal, validated deterministically.
    case onDeviceModel
    /// Vision OCR on device + Claude through the Square Up server (milestone 5), validated
    /// deterministically on the server and again on device.
    case cloudModel
    /// PROTOTYPE: fixed recognized regions for the bundled sample receipt (tests and demos).
    case fixture
    /// Entered by hand.
    case manual
}

nonisolated enum RecognitionStatus: Hashable, Codable, Sendable {
    case notStarted
    /// Recognition was in progress. If seen after relaunch, it was interrupted.
    case inProgress
    case completed
    case failed(RecognitionFailure)
    /// The person chose manual entry.
    case skipped
}

nonisolated enum RecognitionFailure: String, Codable, Sendable, Error {
    case noText
    case unreadableImage
    case interrupted
    case recognizerUnavailable
}

/// Why the on-device parser prepared a receipt instead of AI processing (milestone 5 §6.3).
/// Every case still produces a complete, editable draft.
nonisolated enum ReceiptIntelligenceFallback: String, Codable, Sendable, Error, CaseIterable {
    /// The person chose on-device processing.
    case onDeviceOnly
    /// The person hasn't agreed to AI processing.
    case notConsented
    /// This build has no Square Up server.
    case notConfigured
    case offline
    case serverUnreachable
    /// AI is switched off on the server, or no provider key is configured there.
    case providerUnavailable
    case timedOut
    case rateLimited
    /// Demo Mode: today's AI receipt reading for the demo is used up (the server's demo budget).
    case demoLimitReached
    /// The response failed schema or deterministic checks.
    case invalidResponse
    /// The server refused the request (size, image, or security checks) or the provider declined.
    case refused
    /// The account couldn't sign in.
    case accountUnavailable
    /// The receipt is outside the limits for AI processing (pages, images).
    case ineligible

    /// Whether review explains that the receipt was prepared on device. Not shown when the
    /// person chose that, or never agreed to AI processing.
    var showsNotice: Bool { self != .onDeviceOnly && self != .notConsented }
}

/// What AI processing contributed (milestone 5). Content-free: no model name, prompt, or text.
nonisolated struct CloudProcessingInfo: Hashable, Codable, Sendable {
    var schemaVersion: Int
    /// The server returned a stored result for an identical receipt (no new provider call).
    var cached: Bool
    var durationMilliseconds: Int
    /// The overall confidence the provider reported.
    var overallConfidence: ReceiptAttention
}

/// Provider metadata (milestone 3 §6.4: provider type and duration only — never contents).
nonisolated struct RecognitionInfo: Hashable, Codable, Sendable {
    var status: RecognitionStatus = .notStarted
    var provider: RecognitionProviderKind = .manual
    var durationMilliseconds: Int?
    var regionCount = 0
    var notes: [StructuringNote] = []
    /// Milestone 5: set when AI processing was intended or chosen against, and the on-device
    /// parser prepared the receipt. Optional so drafts saved before milestone 5 still decode.
    var fallback: ReceiptIntelligenceFallback?
    /// Milestone 5: set when the receipt was structured by AI processing.
    var cloud: CloudProcessingInfo?
}

/// The receipt under review (milestone 3 §10.3). Every structured value carries evidence.
nonisolated struct ReceiptDraft: Hashable, Codable, Sendable {
    var pages: [ReceiptAsset]
    var regions: [RecognizedRegion]
    var merchant: ReceiptField<String>
    /// Falls back to the capture date, flagged "Check this", when no date is printed.
    var date: ReceiptField<Date>
    var currency: ReceiptField<CurrencyCode>
    var items: [ReceiptLineItem]
    var charges: [ReceiptCharge]
    /// The printed subtotal, used as a cross-check of the item lines.
    var subtotal: ReceiptField<Money?>
    /// The printed total. Required before the receipt can be confirmed.
    var total: ReceiptField<Money?>
    var recognition: RecognitionInfo
    /// Increments whenever reviewed content changes.
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    /// An empty draft for manual entry or before recognition.
    static func empty(pages: [ReceiptAsset], currency: CurrencyCode, date: Date) -> ReceiptDraft {
        ReceiptDraft(
            pages: pages, regions: [],
            merchant: ReceiptField("", attention: .needsResolution, reason: .notFound),
            date: ReceiptField(date, attention: .check, reason: .notFound),
            currency: ReceiptField(currency, attention: .check, reason: .defaultValue),
            items: [], charges: [],
            subtotal: ReceiptField(nil, attention: .looksGood, reason: .notFound),
            total: ReceiptField(nil, attention: .needsResolution, reason: .notFound),
            recognition: RecognitionInfo(), revision: 1, createdAt: date, updatedAt: date
        )
    }

    var currencyCode: CurrencyCode { currency.value }
    var chargeableItems: [ReceiptLineItem] { items.filter(\.isChargeable) }
    func item(_ id: ReceiptItemID) -> ReceiptLineItem? { items.first { $0.id == id } }
    func charge(_ id: ReceiptChargeID) -> ReceiptCharge? { charges.first { $0.id == id } }
    func region(_ id: ReceiptRegionID) -> RecognizedRegion? { regions.first { $0.id == id } }
    var activePages: [ReceiptAsset] { pages.filter { !$0.isRemoved } }
    var title: String {
        let name = merchant.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Receipt") : name
    }
}
