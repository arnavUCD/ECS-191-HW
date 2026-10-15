import Foundation

/// Typed input to the structure stage (milestone 3 §6.1 stage 4).
nonisolated struct ReceiptStructuringInput: Sendable {
    let pages: [ReceiptAsset]
    let regions: [RecognizedRegion]
    /// The group's currency, or the person's default when no group is chosen yet.
    let defaultCurrency: CurrencyCode
    /// Used when no date is printed (flagged "Check this").
    let captureDate: Date
    /// Seed for deterministic item and charge identifiers.
    let idSeed: UUID
    var timeZone: TimeZone = .current
    /// Read "03/04/2026" as 3 April instead of March 4.
    var prefersDayFirst = false
}

/// A structured proposal: every value editable, every value with evidence (stage 4 output).
nonisolated struct ReceiptProposal: Hashable, Sendable {
    var merchant: ReceiptField<String>
    var date: ReceiptField<Date>
    var currency: ReceiptField<CurrencyCode>
    var items: [ReceiptLineItem]
    var charges: [ReceiptCharge]
    var subtotal: ReceiptField<Money?>
    var total: ReceiptField<Money?>
    var notes: [StructuringNote]

    /// Applies the proposal to a draft, keeping its pages, regions, and identity.
    func applied(to draft: ReceiptDraft) -> ReceiptDraft {
        var draft = draft
        draft.merchant = merchant
        draft.date = date
        draft.currency = currency
        draft.items = items
        draft.charges = charges
        draft.subtotal = subtotal
        draft.total = total
        draft.recognition.notes = notes
        return draft
    }
}

/// Proposes structure from recognized text (milestone 3 §11 `ReceiptStructuring`).
///
/// Implementations may be smarter (an optional on-device model) but must return the same typed
/// proposal, and their money values must pass `ReceiptAmountParser`. The deterministic
/// implementation is always available and is the required fallback.
nonisolated protocol ReceiptStructuring: Sendable {
    var kind: RecognitionProviderKind { get }
    func structure(_ input: ReceiptStructuringInput) async throws -> ReceiptProposal
}

/// The rule-based structurer (milestone 3 §6.3). Works with no model and no network.
///
/// Signals: row geometry, currency and decimal patterns, quantity patterns, summary labels,
/// date patterns, merchant placement, exclusion of card/auth/address/footer text, and arithmetic
/// consistency to rank competing totals. Every value carries its source regions and a reason.
nonisolated struct DeterministicReceiptStructurer: ReceiptStructuring {
    var kind: RecognitionProviderKind { .onDeviceDeterministic }
    /// Below this, a value is flagged "Check this".
    static let confidenceThreshold = 0.5

    func structure(_ input: ReceiptStructuringInput) async throws -> ReceiptProposal {
        Self.propose(input)
    }

    private struct Row {
        let line: ReceiptTextLine
        let role: ReceiptLineRole
        let amount: ParsedAmount?
        let label: String
    }

    /// One linear pass over rows; the order-dependent rules (items end at the first summary row,
    /// payment detail follows the final total) stay together.
    static func propose(_ input: ReceiptStructuringInput) -> ReceiptProposal {
        var salt = 0
        func nextID() -> UUID {
            salt += 1
            return DerivedID.make(input.idSeed, salt)
        }
        let lines = ReceiptTextLayout.lines(from: input.regions, pageOrder: input.pages.map(\.id))
        var notes: [StructuringNote] = []
        if lines.isEmpty { notes.append(.noText) }

        let currencyField = currency(in: lines, default: input.defaultCurrency, notes: &notes)
        let currency = currencyField.value
        let rows = lines.map { line -> Row in
            if let (amount, label) = ReceiptAmountParser.trailingAmount(in: line.text, currency: currency) {
                return Row(line: line, role: ReceiptLineClassifier.role(of: label), amount: amount, label: label)
            }
            return Row(line: line, role: ReceiptLineClassifier.role(of: line.text), amount: nil, label: line.text)
        }

        // Items end at the first summary row (subtotal, tax, or total).
        let summaryStart = rows.firstIndex { [.subtotal, .total, .tax, .taxIncluded].contains($0.role) && $0.amount != nil } ?? rows.endIndex
        var items: [ReceiptLineItem] = []
        var charges: [ReceiptCharge] = []
        var subtotalRows: [Row] = []
        var totalRows: [Row] = []
        var reachedFinalTotal = false

        for (index, row) in rows.enumerated() {
            let inItems = index < summaryStart
            guard let amount = row.amount else {
                if row.role == .tip, !inItems { notes.append(.blankTip) }
                continue
            }
            let attention: ReceiptAttention = row.line.confidence < confidenceThreshold || amount.isAmbiguous ? .check : .looksGood
            let reason: AttentionReason = amount.isAmbiguous ? .ambiguousFormat : (attention == .check ? .lowConfidence : .strongEvidence)
            let field = ReceiptField(amount.money, attention: attention, reason: reason, sources: row.line.regionIDs)
            func charge(_ kind: ReceiptChargeKind, _ label: String, sign: Int = 0) {
                var value = field
                if sign < 0, value.value.isPositive { value = ReceiptField(-amount.money, attention: attention, reason: reason, sources: row.line.regionIDs) }
                charges.append(ReceiptCharge(id: ReceiptChargeID(nextID()), kind: kind, label: label, amount: value))
            }
            let label = row.label.isEmpty ? defaultLabel(for: row.role) : row.label

            // A zero-value line among the items is a note (e.g. a free promotional item), whatever its label.
            if inItems, amount.money.isZero, [.item, .discount, .fee].contains(row.role) {
                items.append(item(row, amount: amount, field: field, currency: currency, id: ReceiptItemID(nextID())))
                continue
            }
            switch row.role {
            case .item where inItems:
                if amount.money.isNegative, !isRefundLabel(row.label) {
                    charge(.discount, label)
                } else {
                    items.append(item(row, amount: amount, field: field, currency: currency, id: ReceiptItemID(nextID())))
                }
            case .discount:
                if !reachedFinalTotal { charge(.discount, label, sign: -1) }
            case .fee:
                if !reachedFinalTotal { charge(.fee, label) }
            case .serviceCharge:
                if !reachedFinalTotal { charge(.serviceCharge, label) }
            case .tax:
                if !reachedFinalTotal, !amount.money.isZero { charge(.tax, label) }
            case .taxIncluded:
                notes.append(.taxIncluded(amount.money))
            case .tip:
                if amount.money.isZero { notes.append(.blankTip) } else { charge(.tip, label) }
            case .rounding:
                if !amount.money.isZero { charge(.adjustment, label) }
            case .subtotal:
                subtotalRows.append(row)
            case .total:
                totalRows.append(row)
                // A tip may follow a pre-tip total; anything else after a total is payment detail.
                reachedFinalTotal = index + 1 < rows.count ? !rows[(index + 1)...].contains { $0.role == .tip && $0.amount != nil } : true
            case .item, .payment, .excluded:
                continue
            }
        }
        markDuplicates(&items)
        if items.isEmpty, !lines.isEmpty { notes.append(.noPricedLines) }

        let itemsSum = items.map(\.amount).sum(in: currency)
        let chargesSum = charges.map(\.value).sum(in: currency)
        let subtotal = subtotalField(subtotalRows, itemsSum: itemsSum, currency: currency)
        let total = totalField(totalRows, expected: itemsSum + chargesSum, notes: &notes)
        return ReceiptProposal(
            merchant: merchant(in: rows, summaryStart: summaryStart),
            date: date(in: lines, input: input),
            currency: currencyField,
            items: items, charges: charges, subtotal: subtotal, total: total, notes: notes
        )
    }

    // MARK: - Fields

    private static func item(_ row: Row, amount: ParsedAmount, field: ReceiptField<Money>, currency: CurrencyCode, id: ReceiptItemID) -> ReceiptLineItem {
        let parsed = ReceiptLineClassifier.quantityAndName(from: row.label, currency: currency)
        let name = parsed.name.isEmpty ? String(localized: "Item") : parsed.name
        var nameField = ReceiptField(name, attention: field.attention == .check && field.reason == .lowConfidence ? .check : .looksGood,
                                     reason: parsed.name.isEmpty ? .notFound : field.reason, sources: row.line.regionIDs)
        if parsed.name.isEmpty { nameField.attention = .check }
        var lineTotal = field
        if let quantity = parsed.quantity, let unit = parsed.unitPrice,
           unit.minorUnits * Int64(quantity) != amount.money.minorUnits {
            lineTotal.attention = .check
            lineTotal.reason = .quantityMismatch
        }
        let isRefund = amount.money.isNegative
        return ReceiptLineItem(
            id: id, name: nameField, quantity: parsed.quantity, unitPrice: parsed.unitPrice, lineTotal: lineTotal, isRefund: isRefund,
            proposal: ItemProposal(name: name, quantity: parsed.quantity, unitPrice: parsed.unitPrice, lineTotal: amount.money)
        )
    }

    private static func isRefundLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["refund", "return", "void", "returned"].contains { lower.contains($0) }
    }

    private static func defaultLabel(for role: ReceiptLineRole) -> String {
        switch role {
        case .tax: String(localized: "Tax")
        case .tip: String(localized: "Tip")
        case .serviceCharge: String(localized: "Service charge")
        case .fee: String(localized: "Fee")
        case .discount: String(localized: "Discount")
        case .rounding: String(localized: "Rounding")
        default: String(localized: "Item")
        }
    }

    /// Adjacent lines with the same name and amount are flagged, never removed (§7.3).
    private static func markDuplicates(_ items: inout [ReceiptLineItem]) {
        guard items.count > 1 else { return }
        for index in 1..<items.count {
            let previous = items[index - 1]
            if previous.name.value.lowercased() == items[index].name.value.lowercased(), previous.amount == items[index].amount {
                items[index].lineTotal.attention = max(items[index].lineTotal.attention, .check)
                items[index].lineTotal.reason = .possibleDuplicate
            }
        }
    }

    private static func currency(in lines: [ReceiptTextLine], default fallback: CurrencyCode, notes: inout [StructuringNote]) -> ReceiptField<CurrencyCode> {
        var found = Set<String>()
        var sources: [ReceiptRegionID] = []
        for line in lines {
            let indicators = ReceiptAmountParser.currencies(in: line.text)
            if !indicators.isEmpty { sources += line.regionIDs.prefix(1) }
            found.formUnion(indicators)
        }
        // "$" is consistent with the default when the default is a dollar currency.
        let resolved = Set(found.map { $0 == "$" ? (ReceiptAmountParser.dollarCurrencies.contains(fallback.rawValue) ? fallback.rawValue : "USD") : $0 })
        if resolved.count > 1 {
            let codes = resolved.sorted().map { CurrencyCode($0) }
            notes.append(.mixedCurrencies(codes))
            return ReceiptField(fallback, attention: .needsResolution, reason: .multipleCandidates, sources: Array(sources.prefix(4)))
        }
        if let only = resolved.first {
            return ReceiptField(CurrencyCode(only), attention: .looksGood, reason: .strongEvidence, sources: Array(sources.prefix(4)))
        }
        return ReceiptField(fallback, attention: .looksGood, reason: .defaultValue)
    }

    private static func merchant(in rows: [Row], summaryStart: Int) -> ReceiptField<String> {
        let headerRows = rows.prefix(summaryStart).filter { $0.line.pageIndex == 0 && $0.line.bounds.y < 0.3 && $0.amount == nil }
        guard let row = headerRows.first(where: { ReceiptLineClassifier.isMerchantCandidate($0.line.text) }) else {
            return ReceiptField("", attention: .needsResolution, reason: .notFound)
        }
        let isFirst = headerRows.first?.line == row.line
        let confident = row.line.confidence >= confidenceThreshold
        return ReceiptField(
            row.line.text, attention: confident && isFirst ? .looksGood : .check,
            reason: confident ? (isFirst ? .strongEvidence : .multipleCandidates) : .lowConfidence, sources: row.line.regionIDs
        )
    }

    private static func date(in lines: [ReceiptTextLine], input: ReceiptStructuringInput) -> ReceiptField<Date> {
        for line in lines {
            if let match = ReceiptDateParser.date(in: line.text, timeZone: input.timeZone, dayFirst: input.prefersDayFirst) {
                let confident = line.confidence >= confidenceThreshold && !match.isAmbiguous
                return ReceiptField(match.date, attention: confident ? .looksGood : .check,
                                    reason: match.isAmbiguous ? .ambiguousFormat : (confident ? .strongEvidence : .lowConfidence),
                                    sources: line.regionIDs)
            }
        }
        return ReceiptField(input.captureDate, attention: .check, reason: .notFound)
    }

    private static func subtotalField(_ rows: [Row], itemsSum: Money, currency: CurrencyCode) -> ReceiptField<Money?> {
        guard let row = rows.first, let amount = row.amount else { return ReceiptField(nil, attention: .looksGood, reason: .notFound) }
        let matches = amount.money == itemsSum
        return ReceiptField(amount.money, attention: matches ? .looksGood : .check, reason: matches ? .strongEvidence : .mathConflict,
                            sources: row.line.regionIDs)
    }

    /// Ranks total candidates by arithmetic consistency (§6.3); never changes a printed value.
    private static func totalField(_ rows: [Row], expected: Money, notes: inout [StructuringNote]) -> ReceiptField<Money?> {
        let candidates = rows.compactMap { row in row.amount.map { (row, $0.money) } }
        let nonZero = candidates.filter { !$0.1.isZero }
        let pool = nonZero.isEmpty ? candidates : nonZero
        guard !pool.isEmpty else { return ReceiptField(nil, attention: .needsResolution, reason: .notFound) }
        if let match = pool.last(where: { $0.1 == expected }) {
            let confident = match.0.line.confidence >= confidenceThreshold
            return ReceiptField(match.1, attention: confident ? .looksGood : .check, reason: confident ? .strongEvidence : .lowConfidence,
                                sources: match.0.line.regionIDs)
        }
        let distinct = Set(pool.map(\.1))
        guard let chosen = pool.last else { return ReceiptField(nil, attention: .needsResolution, reason: .notFound) }
        if distinct.count > 1 {
            notes.append(.multipleTotals(pool.map(\.1)))
            return ReceiptField(chosen.1, attention: .check, reason: .multipleCandidates, sources: chosen.0.line.regionIDs)
        }
        return ReceiptField(chosen.1, attention: .check, reason: .mathConflict, sources: chosen.0.line.regionIDs)
    }
}
