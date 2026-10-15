import Foundation

/// A problem with a reviewed receipt. Blocking issues prevent confirmation; warnings are shown.
nonisolated struct ReceiptIssue: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case merchantMissing
        case totalMissing
        case totalNotPositive
        case noItems
        case itemNameBlank(ReceiptItemID)
        case itemQuantityInvalid(ReceiptItemID)
        case negativeItemNotMarkedRefund(ReceiptItemID)
        case refundNotNegative(ReceiptItemID)
        case chargeSignInvalid(ReceiptChargeID)
        case chargeZero(ReceiptChargeID)
        case adjustmentLabelMissing(ReceiptChargeID)
        /// A proposed line or charge whose amount couldn't be read (AI processing records it as zero,
        /// "Needs resolution") and that the person hasn't corrected or confirmed yet (milestone 5 §6.2).
        case itemNeedsResolution(ReceiptItemID)
        case chargeNeedsResolution(ReceiptChargeID)
        /// A total worked out rather than read as printed (AI processing) that hasn't been confirmed.
        case totalNeedsConfirmation
        case mixedCurrencies
        case currencyDiffersFromGroup(receipt: CurrencyCode, group: CurrencyCode)
        /// Printed total − computed total. Never corrected automatically (§7.2).
        case totalMismatch(difference: Money)
        // Warnings
        case subtotalMismatch(printed: Money, items: Money)
        case quantityTimesPriceMismatch(ReceiptItemID)
        case possibleDuplicate(ReceiptItemID)
        case fieldsToCheck(Int)
    }

    nonisolated enum Severity: Sendable {
        case blocking
        case warning
    }

    let kind: Kind

    var severity: Severity {
        switch kind {
        case .subtotalMismatch, .quantityTimesPriceMismatch, .possibleDuplicate, .fieldsToCheck: .warning
        default: .blocking
        }
    }

    var itemID: ReceiptItemID? {
        switch kind {
        case .itemNameBlank(let id), .itemQuantityInvalid(let id), .negativeItemNotMarkedRefund(let id), .refundNotNegative(let id),
             .quantityTimesPriceMismatch(let id), .possibleDuplicate(let id), .itemNeedsResolution(let id):
            id
        default: nil
        }
    }

    var chargeID: ReceiptChargeID? {
        switch kind {
        case .chargeSignInvalid(let id), .chargeZero(let id), .adjustmentLabelMissing(let id), .chargeNeedsResolution(let id): id
        default: nil
        }
    }
}

/// The canonical receipt equation (milestone 3 §7.1), evaluated exactly:
/// items + tax + tip + service + fees − discounts + adjustments = total.
nonisolated struct ReceiptReconciliation: Equatable, Sendable {
    let currency: CurrencyCode
    let itemsSubtotal: Money
    let tax: Money
    let tip: Money
    let serviceCharges: Money
    let fees: Money
    /// Negative or zero.
    let discounts: Money
    let adjustments: Money
    let computedTotal: Money
    let printedTotal: Money?
    let printedSubtotal: Money?
    let issues: [ReceiptIssue]

    let chargeCount: Int
    let itemCount: Int

    /// printed − computed. Positive: lines are missing money; negative: lines exceed the total.
    var difference: Money? { printedTotal.map { $0 - computedTotal } }
    var isReconciled: Bool { difference?.isZero == true }
    var blockingIssues: [ReceiptIssue] { issues.filter { $0.severity == .blocking } }
    var warnings: [ReceiptIssue] { issues.filter { $0.severity == .warning } }
    var canConfirm: Bool { blockingIssues.isEmpty }

    func issues(for itemID: ReceiptItemID) -> [ReceiptIssue] { issues.filter { $0.itemID == itemID } }
    func issues(for chargeID: ReceiptChargeID) -> [ReceiptIssue] { issues.filter { $0.chargeID == chargeID } }
}

/// Validates types, signs, currency, arithmetic, duplicates, and ambiguity (stage 5).
/// Deterministic; never edits a value.
nonisolated enum ReceiptValidator {
    static func reconcile(_ draft: ReceiptDraft, groupCurrency: CurrencyCode? = nil) -> ReceiptReconciliation {
        let currency = draft.currencyCode
        var issues: [ReceiptIssue] = []
        func add(_ kind: ReceiptIssue.Kind) { issues.append(ReceiptIssue(kind: kind)) }

        let moneyValues = draft.items.map(\.amount) + draft.charges.map(\.value) + [draft.total.value, draft.subtotal.value].compactMap { $0 }
        let unresolvedMixedNote = draft.currency.attention == .needsResolution
            && draft.recognition.notes.contains { if case .mixedCurrencies = $0 { true } else { false } }
        let mixed = moneyValues.contains { $0.currency != currency } || unresolvedMixedNote
        if mixed { add(.mixedCurrencies) }
        if let groupCurrency, groupCurrency != currency { add(.currencyDiffersFromGroup(receipt: currency, group: groupCurrency)) }
        if draft.merchant.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.merchantMissing) }
        if draft.chargeableItems.isEmpty { add(.noItems) }

        issues += itemIssues(draft).map { ReceiptIssue(kind: $0) }
        issues += chargeIssues(draft).map { ReceiptIssue(kind: $0) }

        func sum(_ kinds: Set<ReceiptChargeKind>) -> Money {
            draft.charges.filter { kinds.contains($0.kind) && $0.value.currency == currency }.map(\.value).sum(in: currency)
        }
        let itemsSubtotal = draft.items.map(\.amount).filter { $0.currency == currency }.sum(in: currency)
        let tax = sum([.tax])
        let tip = sum([.tip])
        let service = sum([.serviceCharge])
        let fees = sum([.fee])
        let discounts = sum([.discount])
        let adjustments = sum([.adjustment])
        let computed = itemsSubtotal + tax + tip + service + fees + discounts + adjustments

        let printedTotal = draft.total.value.flatMap { $0.currency == currency ? $0 : nil }
        if let printedTotal {
            if draft.total.reason == .derived, draft.total.attention == .needsResolution, !draft.total.isEdited { add(.totalNeedsConfirmation) }
            if !printedTotal.isPositive { add(.totalNotPositive) }
            if printedTotal != computed { add(.totalMismatch(difference: printedTotal - computed)) }
        } else {
            add(.totalMissing)
        }
        let printedSubtotal = draft.subtotal.value.flatMap { $0.currency == currency ? $0 : nil }
        if let printedSubtotal, printedSubtotal != itemsSubtotal {
            add(.subtotalMismatch(printed: printedSubtotal, items: itemsSubtotal))
        }
        let toCheck = fieldsToCheck(draft)
        if toCheck > 0 { add(.fieldsToCheck(toCheck)) }

        return ReceiptReconciliation(
            currency: currency, itemsSubtotal: itemsSubtotal, tax: tax, tip: tip, serviceCharges: service, fees: fees,
            discounts: discounts, adjustments: adjustments, computedTotal: computed, printedTotal: printedTotal,
            printedSubtotal: printedSubtotal, issues: issues, chargeCount: draft.charges.count, itemCount: draft.chargeableItems.count
        )
    }

    private static func itemIssues(_ draft: ReceiptDraft) -> [ReceiptIssue.Kind] {
        var kinds: [ReceiptIssue.Kind] = []
        for item in draft.items {
            if item.name.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { kinds.append(.itemNameBlank(item.id)) }
            if let quantity = item.quantity, quantity <= 0 { kinds.append(.itemQuantityInvalid(item.id)) }
            if item.amount.isNegative, !item.isRefund { kinds.append(.negativeItemNotMarkedRefund(item.id)) }
            if item.isRefund, !item.amount.isNegative { kinds.append(.refundNotNegative(item.id)) }
            if let quantity = item.quantity, quantity > 0, let unit = item.unitPrice, unit.currency == draft.currencyCode,
               unit.minorUnits * Int64(quantity) != item.amount.minorUnits {
                kinds.append(.quantityTimesPriceMismatch(item.id))
            }
            if item.lineTotal.reason == .possibleDuplicate, item.lineTotal.attention != .looksGood { kinds.append(.possibleDuplicate(item.id)) }
            if item.lineTotal.attention == .needsResolution, item.lineTotal.reason == .notFound, !item.lineTotal.isEdited {
                kinds.append(.itemNeedsResolution(item.id))
            }
        }
        return kinds
    }

    private static func chargeIssues(_ draft: ReceiptDraft) -> [ReceiptIssue.Kind] {
        var kinds: [ReceiptIssue.Kind] = []
        for charge in draft.charges {
            if charge.value.isZero {
                kinds.append(.chargeZero(charge.id))
            } else if (charge.kind.sign > 0 && charge.value.isNegative) || (charge.kind.sign < 0 && charge.value.isPositive) {
                kinds.append(.chargeSignInvalid(charge.id))
            }
            if charge.kind == .adjustment, charge.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                kinds.append(.adjustmentLabelMissing(charge.id))
            }
            if charge.amount.attention == .needsResolution, charge.amount.reason == .notFound, !charge.amount.isEdited {
                kinds.append(.chargeNeedsResolution(charge.id))
            }
        }
        return kinds
    }

    /// Values recognition was unsure about that the person has not touched.
    static func fieldsToCheck(_ draft: ReceiptDraft) -> Int {
        var count = 0
        if draft.merchant.attention == .check, !draft.merchant.isEdited { count += 1 }
        if draft.date.attention == .check, !draft.date.isEdited { count += 1 }
        if draft.total.attention == .check, !draft.total.isEdited { count += 1 }
        count += draft.items.filter { $0.attention == .check && !$0.name.isEdited && !$0.lineTotal.isEdited }.count
        count += draft.charges.filter { $0.amount.attention == .check && !$0.amount.isEdited }.count
        return count
    }
}
