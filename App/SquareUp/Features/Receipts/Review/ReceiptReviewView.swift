import SwiftUI

/// Receipt review (milestone 3 §5.4–5.5): the original image beside every editable value, attention
/// states, and a live reconciliation. "Continue" (to choosing a group or people now) stays disabled
/// until the math is exact.
struct ReceiptReviewView: View {
    let flow: ReceiptFlowModel
    @State private var review: ReceiptReviewModel
    @State private var editingItem: ReceiptItemID?
    @State private var editingCharge: ReceiptChargeID?
    @State private var isShowingReconciliation = false
    @State private var isManagingPages = false
    @State private var isConfirmingReread = false
    @State private var isContinuing = false
    @State private var mismatchCount = 0
    @Environment(\.locale) private var locale

    init(flow: ReceiptFlowModel, review: ReceiptReviewModel) {
        self.flow = flow
        _review = State(initialValue: review)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SUSpacing.lg, pinnedViews: []) {
                pageViewer
                recognitionBanner
                ReconciliationCard(reconciliation: review.reconciliation) { isShowingReconciliation = true }
                detailsCard
                itemsSection
                chargesSection
                totalsCard
                if let error = flow.errorMessage {
                    SUConfirmationBanner(title: String(localized: "Not saved"), message: error, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                // Part of the page, after the totals (not a footer pinned over the receipt).
                continueSection
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.top, SUSpacing.sm)
            .padding(.bottom, SUSpacing.xl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .suScreenBackground()
        .navigationTitle(String(localized: "Review receipt"))
        .task(id: review.editCount) {
            // Autosave after a pause so a closed or killed app keeps the edits.
            guard review.editCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.2))
            await save()
        }
        .onChange(of: review.reconciliation.isReconciled) { _, reconciled in
            if !reconciled { mismatchCount += 1 }
            AccessibilityNotification.Announcement(ReceiptLanguage.reviewStatement(review.reconciliation, locale: locale)).post()
        }
        .sensoryFeedback(.warning, trigger: mismatchCount)
        .sheet(item: Binding(get: { editingItem.map(IdentifiedItem.init) }, set: { editingItem = $0?.id })) { item in
            ReceiptItemEditor(review: review, itemID: item.id)
        }
        .sheet(item: Binding(get: { editingCharge.map(IdentifiedCharge.init) }, set: { editingCharge = $0?.id })) { charge in
            ReceiptChargeEditor(review: review, chargeID: charge.id)
        }
        .sheet(isPresented: $isShowingReconciliation) {
            ReconciliationDetailView(review: review)
        }
        .sheet(isPresented: $isManagingPages) {
            ReceiptPagesView(flow: flow, review: review)
        }
        .confirmationDialog(String(localized: "Read the receipt again?"), isPresented: $isConfirmingReread, titleVisibility: .visible) {
            Button(String(localized: "Read again")) {
                Task {
                    await save()
                    flow.recognize()
                }
            }
        } message: {
            Text(String(localized: "A fresh proposal replaces the values below. Your pages are kept."))
        }
    }

    // MARK: Page viewer

    @ViewBuilder
    private var pageViewer: some View {
        if let page = review.selectedPage {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                ReceiptEvidenceViewer(page: page, highlights: review.highlights(on: page), accessibilityDescription: evidenceDescription)
                    .frame(height: 300)
                    .clipShape(SUShape.card)
                    .accessibilityIdentifier("review.page")
                HStack(spacing: SUSpacing.xs) {
                    if review.draft.activePages.count > 1 {
                        Picker(String(localized: "Page"), selection: Binding(get: { review.selectedPageID ?? page.id }, set: { review.selectedPageID = $0 })) {
                            ForEach(Array(review.draft.activePages.enumerated()), id: \.element.id) { index, page in
                                Text(String(localized: "Page \(index + 1)")).tag(page.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Spacer()
                    Button(String(localized: "Pages"), systemImage: "doc.on.doc") { isManagingPages = true }
                        .font(SUFont.supporting.weight(.semibold))
                        .frame(minHeight: SUMetrics.minimumTouchTarget)
                        .accessibilityIdentifier("review.pages")
                }
                ForEach(page.qualityWarnings, id: \.self) { warning in
                    Label(ReceiptPageLanguage.warning(warning), systemImage: "exclamationmark.triangle")
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.warning)
                }
            }
        } else {
            SUConfirmationBanner(title: String(localized: "No receipt image"), message: String(localized: "Add a page to compare values with the receipt."),
                                 systemImage: "photo", tone: .informational, actionTitle: String(localized: "Pages")) { isManagingPages = true }
        }
    }

    private var evidenceDescription: String {
        guard let focus = review.focus else { return String(localized: "Select a value below to see where it was read.") }
        let text = review.sources(for: focus).compactMap { review.draft.region($0)?.text }.joined(separator: " ")
        return text.isEmpty ? String(localized: "No source text for this value.") : String(localized: "Read as: \(text)")
    }

    // MARK: Status

    @ViewBuilder
    private var recognitionBanner: some View {
        switch review.draft.recognition.status {
        case .inProgress:
            SUConfirmationBanner(title: String(localized: "Reading was interrupted"),
                                 message: String(localized: "Your pages are safe. Read the receipt again or enter the details yourself."),
                                 systemImage: "arrow.clockwise", tone: .warning, actionTitle: String(localized: "Read again")) { flow.recognize() }
        case .failed(let failure):
            SUConfirmationBanner(title: failure == .noText ? String(localized: "No text found") : String(localized: "Couldn't read this receipt"),
                                 message: String(localized: "Retake or import a clearer image from Pages, or add the items yourself below."),
                                 systemImage: "text.magnifyingglass", tone: .warning, actionTitle: String(localized: "Read again")) { isConfirmingReread = true }
        case .skipped, .notStarted:
            SUConfirmationBanner(title: String(localized: "Entering manually"), message: String(localized: "Add items and amounts below."),
                                 systemImage: "square.and.pencil", tone: .informational,
                                 actionTitle: review.draft.activePages.isEmpty ? nil : String(localized: "Read receipt")) { isConfirmingReread = true }
        case .completed:
            let toCheck = ReceiptValidator.fieldsToCheck(review.draft)
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                // Milestone 5: AI processing was intended but the on-device parser prepared this
                // receipt. Calm and informational: the draft is complete and editable either way.
                if review.draft.recognition.fallback?.showsNotice == true {
                    Label(ReceiptLanguage.preparedOnDevice(review.draft.recognition.fallback), systemImage: "iphone")
                        .font(SUFont.metadata)
                        .foregroundStyle(SUColor.textSecondary)
                        .accessibilityIdentifier("receipt.preparedOnDevice")
                }
                // How it was read isn't shown (kept simple); VoiceOver still hears it.
                SpokenOnly(text: review.draft.recognition.provider == .cloudModel
                    ? (toCheck == 0 ? String(localized: "Items identified with AI. Check the values against the receipt.")
                        : Inflect.string("Items identified with AI. Check ^[\(toCheck) value](inflect: true) against the receipt."))
                    : (toCheck == 0 ? String(localized: "Read on this iPhone. Check the values against the receipt.")
                        : Inflect.string("Read on this iPhone. Check ^[\(toCheck) value](inflect: true) against the receipt.")))
            }
        }
    }

    // MARK: Details

    private var detailsCard: some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                fieldHeader(String(localized: "Merchant"), field: review.draft.merchant.attention, focus: .merchant)
                TextField(String(localized: "Merchant"), text: Binding(get: { review.draft.merchant.value }, set: { review.setMerchant($0) }),
                          prompt: Text(String(localized: "Where was this?")))
                    .font(SUFont.body.weight(.semibold))
                    .textInputAutocapitalization(.words)
                    .frame(minHeight: SUMetrics.minimumTouchTarget)
                    .padding(.horizontal, SUSpacing.sm)
                    .suSurface(SUShape.control, elevated: true)
                    .accessibilityIdentifier("review.merchant")
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        fieldHeader(String(localized: "Date"), field: review.draft.date.attention, focus: .date)
                        dateField
                    }
                    VStack(alignment: .leading) {
                        fieldHeader(String(localized: "Date"), field: review.draft.date.attention, focus: .date)
                        dateField
                    }
                }
                Divider()
                LabeledContent(String(localized: "Currency")) {
                    Picker(String(localized: "Currency"), selection: Binding(get: { review.currency }, set: { review.setCurrency($0) })) {
                        ForEach(review.currencyChoices, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                .font(SUFont.body)
                if review.draft.currency.attention != .looksGood {
                    ReceiptAttentionChip(attention: review.draft.currency.attention)
                }
            }
        }
    }

    private var dateField: some View {
        DatePicker(String(localized: "Date"), selection: Binding(get: { review.draft.date.value }, set: { review.setDate($0) }), displayedComponents: .date)
            .labelsHidden()
    }

    private func fieldHeader(_ title: String, field attention: ReceiptAttention, focus: ReceiptReviewModel.Focus) -> some View {
        HStack(spacing: SUSpacing.xs) {
            Text(title).font(SUFont.metadata.weight(.semibold)).foregroundStyle(SUColor.textSecondary).fixedSize()
            if attention != .looksGood { ReceiptAttentionChip(attention: attention, compact: true) }
            Spacer(minLength: 0)
            if !review.sources(for: focus).isEmpty {
                Button {
                    review.show(focus)
                } label: {
                    Image(systemName: "eye").frame(minWidth: SUMetrics.minimumTouchTarget, minHeight: 32)
                }
                .accessibilityLabel(String(localized: "Show \(title) on the receipt"))
            }
        }
    }

    // MARK: Items and charges

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            SUSectionHeader(title: String(localized: "Items"), subtitle: Inflect.string("^[\(review.draft.items.count) line](inflect: true)"),
                            actionTitle: String(localized: "Add item")) {
                editingItem = review.addItem()
            }
            SUCard(padding: SUSpacing.xs) {
                LazyVStack(spacing: 0) {
                    if review.draft.items.isEmpty {
                        Text(String(localized: "No items yet. Add each line from the receipt."))
                            .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary).padding(SUSpacing.sm)
                    }
                    ForEach(review.draft.items) { item in
                        Button {
                            review.show(.item(item.id))
                            editingItem = item.id
                        } label: {
                            ReceiptLineRow(
                                title: item.name.value, detail: quantityText(item), amount: item.amount,
                                attention: itemAttention(item), reason: itemReason(item), isSelected: review.focus == .item(item.id),
                                badge: item.isRefund ? String(localized: "Refund") : (item.isNote ? String(localized: "Note") : nil)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.item.\(item.name.value)")
                        if item.id != review.draft.items.last?.id { Divider().padding(.leading, SUSpacing.xs) }
                    }
                }
            }
        }
    }

    private var chargesSection: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack {
                SUSectionHeader(title: String(localized: "Tax, tip, fees & discounts"))
                Menu {
                    ForEach(ReceiptChargeKind.allCases, id: \.self) { kind in
                        Button(ReceiptLanguage.name(kind), systemImage: ReceiptLanguage.symbol(kind)) { editingCharge = review.addCharge(kind) }
                    }
                } label: {
                    Label(String(localized: "Add"), systemImage: "plus").font(SUFont.supporting.weight(.semibold))
                        .frame(minHeight: SUMetrics.minimumTouchTarget)
                }
                .accessibilityLabel(String(localized: "Add a charge or discount"))
                .accessibilityIdentifier("review.addCharge")
            }
            if !review.draft.charges.isEmpty {
                SUCard(padding: SUSpacing.xs) {
                    VStack(spacing: 0) {
                        ForEach(review.draft.charges) { charge in
                            Button {
                                review.show(.charge(charge.id))
                                editingCharge = charge.id
                            } label: {
                                ReceiptLineRow(
                                    title: charge.label.isEmpty ? ReceiptLanguage.name(charge.kind) : charge.label,
                                    detail: charge.label == ReceiptLanguage.name(charge.kind) ? nil : ReceiptLanguage.name(charge.kind),
                                    amount: charge.value,
                                    attention: chargeAttention(charge), reason: ReceiptLanguage.reason(charge.amount.reason),
                                    isSelected: review.focus == .charge(charge.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("review.charge.\(charge.kind.rawValue)")
                            if charge.id != review.draft.charges.last?.id { Divider().padding(.leading, SUSpacing.xs) }
                        }
                    }
                }
            }
        }
    }

    private var totalsCard: some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                fieldHeader(String(localized: "Printed subtotal (optional)"), field: review.draft.subtotal.attention, focus: .subtotal)
                ReceiptMoneyField(title: String(localized: "Subtotal"), value: review.draft.subtotal.value, currency: review.currency,
                                  allowsEmpty: true, identifier: "review.subtotal") { review.setSubtotal($0) }
                Divider()
                fieldHeader(String(localized: "Receipt total"), field: totalAttention, focus: .total)
                ReceiptMoneyField(title: String(localized: "Total"), value: review.draft.total.value, currency: review.currency,
                                  allowsEmpty: true, identifier: "review.total") { review.setTotal($0) }
            }
        }
    }

    // MARK: Continue

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            if review.canContinue {
                // The reconciliation card above already says this on screen.
                SpokenOnly(text: ReceiptLanguage.reviewStatement(review.reconciliation, locale: locale))
                    .accessibilityIdentifier("review.statement")
            } else if let first = review.blockers.first {
                Label(first, systemImage: "exclamationmark.circle")
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .accessibilityIdentifier("review.blocker")
            }
            Button {
                Task { await continueToRoom() }
            } label: {
                Label(String(localized: "Continue"), systemImage: "arrow.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .disabled(!review.canContinue || isContinuing)
            .accessibilityIdentifier("review.continue")
            .accessibilityHint(review.canContinue ? "" : review.blockers.joined(separator: " "))
        }
        .padding(.top, SUSpacing.sm)
    }

    private func save() async {
        guard let room = flow.room, room.state == .draft else { return }
        await flow.run(review.saveCommand(for: room))
    }

    /// Saves the reviewed receipt, then asks where it's going: a group, or people right now.
    private func continueToRoom() async {
        isContinuing = true
        defer { isContinuing = false }
        await save()
        guard flow.room != nil, flow.errorMessage == nil else { return }
        flow.show(.choosing)
    }

    // MARK: Text helpers

    private func quantityText(_ item: ReceiptLineItem) -> String? {
        guard let quantity = item.quantity else { return nil }
        if let unit = item.unitPrice { return String(localized: "\(quantity) × \(MoneyFormatting.string(unit, locale: locale))") }
        return String(localized: "Qty \(quantity)")
    }

    private func itemAttention(_ item: ReceiptLineItem) -> ReceiptAttention {
        review.reconciliation.issues(for: item.id).contains { $0.severity == .blocking } ? .needsResolution
            : (item.name.isEdited && item.lineTotal.isEdited ? .looksGood : item.attention)
    }

    private func itemReason(_ item: ReceiptLineItem) -> String? {
        if let issue = review.reconciliation.issues(for: item.id).first { return ReceiptLanguage.issue(issue.kind, in: review.draft) }
        return ReceiptLanguage.reason(item.lineTotal.attention >= item.name.attention ? item.lineTotal.reason : item.name.reason)
    }

    private func chargeAttention(_ charge: ReceiptCharge) -> ReceiptAttention {
        review.reconciliation.issues(for: charge.id).contains { $0.severity == .blocking } ? .needsResolution
            : (charge.amount.isEdited ? .looksGood : charge.amount.attention)
    }

    private var totalAttention: ReceiptAttention {
        review.reconciliation.isReconciled ? (review.draft.total.isEdited ? .looksGood : review.draft.total.attention) : .needsResolution
    }
}

private struct IdentifiedItem: Identifiable {
    let id: ReceiptItemID
}

private struct IdentifiedCharge: Identifiable {
    let id: ReceiptChargeID
}

/// The live equation summary (§7.1) with the exact difference when it doesn't balance.
struct ReconciliationCard: View {
    let reconciliation: ReceiptReconciliation
    let showDetails: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: showDetails) {
            HStack(alignment: .top, spacing: SUSpacing.sm) {
                Image(systemName: reconciliation.isReconciled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(reconciliation.isReconciled ? SUColor.positive : SUColor.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reconciliation.isReconciled ? String(localized: "Adds up exactly") : String(localized: "Doesn't add up yet"))
                        .font(SUFont.cardTitle)
                        .foregroundStyle(SUColor.textPrimary)
                    Text(ReceiptLanguage.reviewStatement(reconciliation, locale: locale))
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if let difference = reconciliation.difference, !difference.isZero {
                    SUAmountView(money: difference.magnitude, direction: .neutral, style: .row)
                        .accessibilityLabel(String(localized: "Difference \(MoneyFormatting.spokenString(difference.magnitude, locale: locale))"))
                }
            }
            .padding(SUSpacing.md)
            .background((reconciliation.isReconciled ? SUColor.positive : SUColor.warning).opacity(0.12), in: SUShape.card)
            .contentShape(SUShape.card)
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Shows each part of the total"))
        .accessibilityIdentifier("review.reconciliation")
    }
}

/// Text for VoiceOver only: nothing on screen, no space taken.
private struct SpokenOnly: View {
    let text: String

    var body: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}
