import SwiftUI

/// Edits one line: name, quantity, unit price, line total, refund; merge, split, move, delete
/// (milestone 3 §5.4). The evidence is shown above the fields for comparison.
struct ReceiptItemEditor: View {
    let review: ReceiptReviewModel
    let itemID: ReceiptItemID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quantityText = ""
    @State private var unitPrice: Money?
    @State private var lineTotal: Money?
    @State private var isRefund = false
    @State private var splitAmount: Money?
    @State private var isSplitting = false
    @State private var loaded = false

    private var item: ReceiptLineItem? { review.draft.item(itemID) }

    var body: some View {
        NavigationStack {
            Form {
                if let item, let page = evidencePage(for: item) {
                    Section {
                        ReceiptEvidenceViewer(page: page, highlights: highlights(for: item, on: page),
                                              accessibilityDescription: evidenceText(item))
                            .frame(height: 170)
                            .listRowInsets(EdgeInsets())
                        if let proposal = item.proposal, proposal.lineTotal != lineTotal || proposal.name != name {
                            Text(String(localized: "Originally read as \u{201C}\(proposal.name)\u{201D} \(MoneyFormatting.string(proposal.lineTotal))"))
                                .font(SUFont.metadata)
                                .foregroundStyle(SUColor.textSecondary)
                        }
                    } footer: {
                        if item.attention != .looksGood {
                            Label(ReceiptLanguage.reason(item.lineTotal.attention >= item.name.attention ? item.lineTotal.reason : item.name.reason),
                                  systemImage: ReceiptLanguage.symbol(item.attention))
                        }
                    }
                    .suListRows()
                }
                Section(String(localized: "Item")) {
                    TextField(String(localized: "Name"), text: $name, prompt: Text(String(localized: "What was it?")), axis: .vertical)
                        .accessibilityIdentifier("item.name")
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(String(localized: "Every item needs a name.")).font(SUFont.metadata).foregroundStyle(SUColor.negative)
                    }
                    TextField(String(localized: "Quantity (optional)"), text: $quantityText)
                        .keyboardType(.numberPad)
                    ReceiptMoneyField(title: String(localized: "Unit price"), value: unitPrice, currency: review.currency, allowsEmpty: true) { unitPrice = $0 }
                    ReceiptMoneyField(title: String(localized: "Line total"), value: lineTotal, currency: review.currency, allowsNegative: true,
                                      identifier: "item.total") { value in
                        lineTotal = value
                        if let value { isRefund = value.isNegative }
                    }
                    Toggle(String(localized: "Refund or return"), isOn: $isRefund)
                    if let quantity = Int(quantityText), let unitPrice, let lineTotal, unitPrice.minorUnits * Int64(quantity) != lineTotal.minorUnits {
                        Label(String(localized: "Quantity × price is \(MoneyFormatting.string(Money(minorUnits: unitPrice.minorUnits * Int64(quantity), currency: review.currency)))."),
                              systemImage: "exclamationmark.triangle")
                            .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                    }
                    if lineTotal?.isZero == true {
                        Text(String(localized: "A zero line is kept as a note and isn't split.")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                }
                .suListRows()
                Section(String(localized: "Fix recognition")) {
                    Button(String(localized: "Merge with the next line"), systemImage: "arrow.down.right.and.arrow.up.left") {
                        apply()
                        review.mergeWithNext(itemID)
                        dismiss()
                    }
                    .disabled(!review.canMove(itemID, by: 1))
                    Button(String(localized: "Split into two lines"), systemImage: "scissors") { isSplitting.toggle() }
                    if isSplitting {
                        ReceiptMoneyField(title: String(localized: "First line's amount"), value: splitAmount, currency: review.currency,
                                          allowsNegative: true) { splitAmount = $0 }
                        Button(String(localized: "Split")) {
                            apply()
                            if let splitAmount { review.split(itemID, firstAmount: splitAmount) }
                            dismiss()
                        }
                        .disabled(splitAmount == nil || splitAmount == lineTotal || splitAmount?.isZero == true)
                    }
                    Button(String(localized: "Move up"), systemImage: "arrow.up") { review.moveItem(itemID, by: -1) }
                        .disabled(!review.canMove(itemID, by: -1))
                    Button(String(localized: "Move down"), systemImage: "arrow.down") { review.moveItem(itemID, by: 1) }
                        .disabled(!review.canMove(itemID, by: 1))
                }
                .suListRows()
                Section {
                    Button(String(localized: "Delete item"), systemImage: "trash", role: .destructive) {
                        review.deleteItem(itemID)
                        dismiss()
                    }
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Edit item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        apply()
                        dismiss()
                    }
                    .disabled(lineTotal == nil)
                    .accessibilityIdentifier("item.done")
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func load() {
        guard !loaded, let item else { return }
        loaded = true
        name = item.name.value
        quantityText = item.quantity.map(String.init) ?? ""
        unitPrice = item.unitPrice
        lineTotal = item.amount
        isRefund = item.isRefund
    }

    private func apply() {
        guard let lineTotal else { return }
        review.updateItem(itemID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), quantity: Int(quantityText),
                          unitPrice: unitPrice, lineTotal: lineTotal, isRefund: isRefund)
    }

    private func evidencePage(for item: ReceiptLineItem) -> ReceiptAsset? {
        let pageID = item.sourceRegionIDs.compactMap { review.draft.region($0)?.pageID }.first
        return review.draft.activePages.first { $0.id == pageID }
    }

    private func highlights(for item: ReceiptLineItem, on page: ReceiptAsset) -> [ReceiptRect] {
        item.sourceRegionIDs.compactMap { review.draft.region($0) }.filter { $0.pageID == page.id }.map(\.bounds)
    }

    private func evidenceText(_ item: ReceiptLineItem) -> String {
        let text = item.sourceRegionIDs.compactMap { review.draft.region($0)?.text }.joined(separator: " ")
        return String(localized: "Read as: \(text)")
    }
}

/// Edits a tax, tip, fee, discount, or adjustment.
struct ReceiptChargeEditor: View {
    let review: ReceiptReviewModel
    let chargeID: ReceiptChargeID
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReceiptChargeKind = .tax
    @State private var label = ""
    @State private var amount: Money?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Type"), selection: $kind) {
                        ForEach(ReceiptChargeKind.allCases, id: \.self) { Label(ReceiptLanguage.name($0), systemImage: ReceiptLanguage.symbol($0)).tag($0) }
                    }
                    TextField(kind == .adjustment ? String(localized: "Why? (required)") : String(localized: "Label"), text: $label)
                        .accessibilityIdentifier("charge.label")
                    ReceiptMoneyField(title: String(localized: "Amount"), value: amount, currency: review.currency, allowsNegative: kind != .tax && kind != .tip,
                                      identifier: "charge.amount") { amount = $0 }
                } footer: {
                    Text(footer)
                }
                .suListRows()
                Section {
                    Button(String(localized: "Remove"), systemImage: "trash", role: .destructive) {
                        review.deleteCharge(chargeID)
                        dismiss()
                    }
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(ReceiptLanguage.name(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        if let amount {
                            let signed = kind == .discount && amount.isPositive ? -amount : amount
                            review.updateCharge(chargeID, kind: kind, label: label.trimmingCharacters(in: .whitespacesAndNewlines), amount: signed)
                        }
                        dismiss()
                    }
                    .disabled(amount == nil || (kind == .adjustment && label.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("charge.done")
                }
            }
            .onAppear {
                guard !loaded, let charge = review.draft.charge(chargeID) else { return }
                loaded = true
                kind = charge.kind
                label = charge.label
                amount = charge.value.isZero ? nil : charge.value
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        switch kind {
        case .discount: String(localized: "Discounts reduce the total. Enter 4.00 or -4.00; it's stored as a credit.")
        case .adjustment: String(localized: "Use only when the receipt itself has an unexplained difference, such as printed rounding. A label is required.")
        default: String(localized: "Who pays this is decided in the room. By default, in proportion to each person's items.")
        }
    }
}

/// Every term of the receipt equation and the exact difference (§13.2 "Reconciliation detail").
struct ReconciliationDetailView: View {
    let review: ReceiptReviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            let reconciliation = review.reconciliation
            List {
                Section {
                    row(String(localized: "Items"), reconciliation.itemsSubtotal)
                    if !reconciliation.discounts.isZero { row(String(localized: "Discounts"), reconciliation.discounts) }
                    if !reconciliation.tax.isZero { row(String(localized: "Tax"), reconciliation.tax) }
                    if !reconciliation.tip.isZero { row(String(localized: "Tip"), reconciliation.tip) }
                    if !reconciliation.serviceCharges.isZero { row(String(localized: "Service charges"), reconciliation.serviceCharges) }
                    if !reconciliation.fees.isZero { row(String(localized: "Fees"), reconciliation.fees) }
                    if !reconciliation.adjustments.isZero { row(String(localized: "Adjustments"), reconciliation.adjustments) }
                    row(String(localized: "Lines add up to"), reconciliation.computedTotal, emphasized: true)
                    if let printed = reconciliation.printedTotal { row(String(localized: "Receipt total"), printed, emphasized: true) }
                } footer: {
                    Text(ReceiptLanguage.reviewStatement(reconciliation, locale: locale))
                }
                .suListRows()
                if let difference = reconciliation.difference, !difference.isZero {
                    Section(String(localized: "How to fix it")) {
                        Text(String(localized: """
                        Compare each line with the receipt and correct the one that was misread. \
                        If the receipt itself doesn't add up, record the difference as a labelled adjustment.
                        """))
                        .font(SUFont.supporting)
                        Button(String(localized: "Add a \(MoneyFormatting.signedString(difference, locale: locale)) adjustment"), systemImage: "plusminus") {
                            review.addCharge(.adjustment, amount: difference, label: "")
                            dismiss()
                        }
                        .accessibilityIdentifier("reconciliation.addAdjustment")
                    }
                    .suListRows()
                }
                if !reconciliation.issues.isEmpty {
                    Section(String(localized: "To review")) {
                        ForEach(Array(reconciliation.issues.enumerated()), id: \.offset) { _, issue in
                            Label(ReceiptLanguage.issue(issue.kind, in: review.draft, locale: locale),
                                  systemImage: issue.severity == .blocking ? "exclamationmark.triangle.fill" : "eye")
                                .foregroundStyle(issue.severity == .blocking ? SUColor.negative : SUColor.textPrimary)
                        }
                    }
                    .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Receipt math"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
    }

    private func row(_ title: String, _ money: Money, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).font(emphasized ? SUFont.body.weight(.semibold) : SUFont.body)
            Spacer()
            Text(MoneyFormatting.signedString(money, locale: locale).replacingOccurrences(of: "+", with: ""))
                .font(emphasized ? SUFont.rowAmount : SUFont.body.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}
