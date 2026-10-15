import Foundation

/// Turns a server receipt-intelligence response into the same `ReceiptProposal` the on-device
/// structurer produces (milestone 5 §3.1, M5.4).
///
/// The server already validated the provider's output, but nothing from the network is trusted
/// here either: the schema version, currency, every amount's bounds, every attention state, and
/// every region reference are checked again. Any violation rejects the whole response, and the
/// pipeline falls back to the deterministic parser. Values are never adjusted to reconcile.
nonisolated enum ReceiptIntelligenceMapper {
    /// Largest absolute amount accepted (matches the server's `MAX_ABS_MINOR_UNITS`).
    static let maximumMinorUnits: Int64 = 100_000_000_000

    static func proposal(from response: ReceiptIntelligenceDTO.Response, input: ReceiptStructuringInput)
        throws(ReceiptIntelligenceFallback) -> ReceiptProposal {
        guard response.schemaVersion == ReceiptIntelligenceDTO.schemaVersion else { throw .invalidResponse }
        let dto = response.proposal
        guard let code = dto.currency.value, code.count == 3, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw .invalidResponse }
        let currency = CurrencyCode(code)
        let known = Set(input.regions.map(\.id))

        var salt = 0
        func nextID() -> UUID {
            salt += 1
            return DerivedID.make(input.idSeed, salt)
        }
        func money(_ units: Int64) throws(ReceiptIntelligenceFallback) -> Money {
            guard units.magnitude <= UInt64(maximumMinorUnits) else { throw .invalidResponse }
            return Money(minorUnits: units, currency: currency)
        }
        func field<Value: Hashable & Codable & Sendable, Wire>(
            _ wire: ReceiptIntelligenceDTO.Field<Wire>, _ value: Value
        ) throws(ReceiptIntelligenceFallback) -> ReceiptField<Value> {
            var (attention, reason) = try state(wire)
            // Sign and zero problems are blocking issues of their own in `ReceiptValidator`; show
            // them as "Check this" rather than listing the same line twice.
            if attention == .needsResolution, reason == .invalidValue { attention = .check }
            let sources = wire.regionIds.compactMap(UUID.init(uuidString:)).map(ReceiptRegionID.init).filter(known.contains)
            return ReceiptField(value, attention: attention, reason: reason, sources: sources)
        }

        let merchant = try field(dto.merchant, (dto.merchant.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        // Same rule as the on-device parser: no printed date → the capture date, flagged "Check this".
        let date: ReceiptField<Date> = if let text = dto.date.value,
                                          let match = ReceiptDateParser.date(in: text, timeZone: input.timeZone, dayFirst: false) {
            try field(dto.date, match.date)
        } else {
            ReceiptField(input.captureDate, attention: .check, reason: .notFound)
        }

        var items: [ReceiptLineItem] = []
        for wire in dto.items {
            guard let units = wire.lineTotal.value else { throw .invalidResponse }
            let lineTotal = try money(units)
            let unitPrice = try wire.unitPrice.map { units throws(ReceiptIntelligenceFallback) in try money(units) }
            guard wire.quantity.map({ (1...9999).contains($0) }) ?? true else { throw .invalidResponse }
            let name = (wire.name.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(ReceiptLineItem(
                id: ReceiptItemID(nextID()), name: try field(wire.name, name), quantity: wire.quantity, unitPrice: unitPrice,
                lineTotal: try field(wire.lineTotal, lineTotal), isRefund: wire.isRefund,
                proposal: ItemProposal(name: name, quantity: wire.quantity, unitPrice: unitPrice, lineTotal: lineTotal)
            ))
        }

        var charges: [ReceiptCharge] = []
        for wire in dto.charges {
            guard let kind = ReceiptChargeKind(rawValue: wire.kind), let units = wire.amount.value else { throw .invalidResponse }
            let label = wire.label.trimmingCharacters(in: .whitespacesAndNewlines)
            charges.append(ReceiptCharge(
                id: ReceiptChargeID(nextID()), kind: kind, label: label.isEmpty && kind != .adjustment ? defaultLabel(kind) : label,
                amount: try field(wire.amount, try money(units))
            ))
        }

        let subtotal = try field(dto.subtotal, try dto.subtotal.value.map { units throws(ReceiptIntelligenceFallback) in try money(units) })
        let total = try field(dto.total, try dto.total.value.map { units throws(ReceiptIntelligenceFallback) in try money(units) })
        var notes: [StructuringNote] = dto.notes.contains { $0.kind == "blankCharge" && $0.chargeKind == "tip" } ? [.blankTip] : []
        if items.isEmpty { notes.append(.noPricedLines) }
        return ReceiptProposal(
            merchant: merchant, date: date, currency: try field(dto.currency, currency), items: items, charges: charges,
            subtotal: subtotal, total: total, notes: notes
        )
    }

    static func overallConfidence(_ wire: String) -> ReceiptAttention {
        switch wire {
        case "high": .looksGood
        case "medium": .check
        default: .needsResolution
        }
    }

    private static func state<Wire>(_ wire: ReceiptIntelligenceDTO.Field<Wire>) throws(ReceiptIntelligenceFallback)
        -> (ReceiptAttention, AttentionReason) {
        let attention: ReceiptAttention
        switch wire.attention {
        case "looksGood": attention = .looksGood
        case "check": attention = .check
        case "needsResolution": attention = .needsResolution
        default: throw .invalidResponse
        }
        // Reasons a person could set (confirmed/entered) never come from the server.
        let reason = AttentionReason(rawValue: wire.reason).flatMap { [.confirmedByPerson, .enteredByPerson].contains($0) ? nil : $0 }
        return (attention, reason ?? (attention == .looksGood ? .strongEvidence : .lowConfidence))
    }

    private static func defaultLabel(_ kind: ReceiptChargeKind) -> String {
        switch kind {
        case .tax: String(localized: "Tax")
        case .tip: String(localized: "Tip")
        case .serviceCharge: String(localized: "Service charge")
        case .fee: String(localized: "Fee")
        case .discount: String(localized: "Discount")
        case .adjustment: String(localized: "Adjustment")
        }
    }
}
