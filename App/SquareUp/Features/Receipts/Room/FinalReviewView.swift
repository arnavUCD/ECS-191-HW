import SwiftUI

/// Host edits after claims began (§8.11). The effect on claims is explained before saving.
struct RoomReceiptEditor: View {
    let flow: ReceiptFlowModel
    @State var review: ReceiptReviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editingItem: ReceiptItemID?
    @State private var editingCharge: ReceiptChargeID?
    @State private var isConfirming = false

    private var impact: (change: ReceiptRevisionChange, cleared: [ReceiptClaim])? {
        guard let room = flow.room else { return nil }
        let change = ReceiptRevisionImpact.change(from: room.receipt, to: review.draft)
        return (change, ReceiptRevisionImpact.clearedClaims(in: room, for: change))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ReconciliationCard(reconciliation: review.reconciliation) {}
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .suListRows()
                Section(String(localized: "Items")) {
                    ForEach(review.draft.items) { item in
                        Button { editingItem = item.id } label: {
                            ReceiptLineRow(title: item.name.value, detail: nil, amount: item.amount, attention: .looksGood, reason: nil)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(String(localized: "Add item"), systemImage: "plus") { editingItem = review.addItem() }
                }
                .suListRows()
                Section(String(localized: "Charges")) {
                    ForEach(review.draft.charges) { charge in
                        Button { editingCharge = charge.id } label: {
                            ReceiptLineRow(title: charge.label, detail: ReceiptLanguage.name(charge.kind), amount: charge.value, attention: .looksGood, reason: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .suListRows()
                Section {
                    ReceiptMoneyField(title: String(localized: "Receipt total"), value: review.draft.total.value, currency: review.currency) { review.setTotal($0) }
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Edit receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        if impact?.cleared.isEmpty == false { isConfirming = true } else { save() }
                    }
                }
            }
            .sheet(item: Binding(get: { editingItem.map(EditorItemRef.init) }, set: { editingItem = $0?.id })) { ReceiptItemEditor(review: review, itemID: $0.id) }
            .sheet(item: Binding(get: { editingCharge.map(EditorChargeRef.init) }, set: { editingCharge = $0?.id })) { ReceiptChargeEditor(review: review, chargeID: $0.id) }
            .confirmationDialog(String(localized: "Clear affected claims?"), isPresented: $isConfirming, titleVisibility: .visible) {
                Button(String(localized: "Save and clear claims"), role: .destructive) { save() }
            } message: {
                Text(impactMessage)
            }
        }
    }

    private var impactMessage: String {
        guard let impact, let room = flow.room else { return "" }
        let items = Set(impact.cleared.map(\.itemID)).compactMap { room.receipt.item($0)?.name.value }.formatted(.list(type: .and))
        let people = Set(impact.cleared.map(\.memberID)).compactMap { flow.snapshot?.members[$0]?.firstName }.sorted().formatted(.list(type: .and))
        return String(localized: "Changing \(items) removes the claims on it. \(people) will be asked to review again. The previous values stay in the room's history.")
    }

    private func save() {
        guard let room = flow.room else { return }
        Task {
            if await flow.run(.reviseReceipt(room.id, expectedRevision: room.revision, review.draft), asHost: true) != nil { dismiss() }
        }
    }
}

private struct EditorItemRef: Identifiable {
    let id: ReceiptItemID
}

private struct EditorChargeRef: Identifiable {
    let id: ReceiptChargeID
}

/// Final review (§9.2): every participant's items and charges, rounding disclosures, any
/// adjustment, and a direct statement proving the allocation adds to the total.
struct FinalReviewView: View {
    let flow: ReceiptFlowModel
    @State private var isFinalizing = false
    @State private var failureCount = 0
    /// People whose unreviewed share the host chose to finalize for them (temporary rooms and
    /// group receipts never finalize anyone's share silently).
    @State private var acknowledged: Set<MemberID> = []
    @Environment(\.locale) private var locale

    /// Who hasn't reviewed their current share, by the server's count.
    private var unreviewed: [MemberID] { (flow.remote?.base?.unreviewed ?? []).map(RemoteRoomMapper.member) }
    private var needsAcknowledgement: Bool { flow.remote?.isTemporary == true || flow.remote?.isGroupReceipt == true }
    private var waitingOn: [MemberID] { needsAcknowledgement ? unreviewed.filter { !acknowledged.contains($0) } : [] }

    var body: some View {
        if let room = flow.room, let snapshot = flow.snapshot {
            let summary = ReceiptRoomSummary.make(room: room, snapshot: snapshot, actorID: room.hostID)
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    header(summary)
                    if needsAcknowledgement, !unreviewed.isEmpty { unreviewedPanel(summary) }
                    ForEach(summary.allocation.participants.filter { !$0.total.isZero || $0.memberID == room.payerID }, id: \.memberID) { participant in
                        ParticipantBreakdown(summary: summary, participant: participant)
                    }
                    if !summary.allocation.rounding.isEmpty {
                        VStack(alignment: .leading, spacing: SUSpacing.xs) {
                            SUSectionHeader(title: String(localized: "Rounding"))
                            ForEach(summary.allocation.rounding, id: \.self) { note in
                                Label(ReceiptLanguage.rounding(note, receipt: room.receipt, names: summary.names, locale: locale), systemImage: "info.circle")
                                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            }
                        }
                    }
                    let adjustments = room.receipt.charges.filter { $0.kind == .adjustment }
                    if !adjustments.isEmpty {
                        VStack(alignment: .leading, spacing: SUSpacing.xs) {
                            SUSectionHeader(title: String(localized: "Manual adjustments"))
                            ForEach(adjustments) { charge in
                                Label("\(charge.label): \(MoneyFormatting.signedString(charge.value, locale: locale))", systemImage: "plusminus")
                                    .font(SUFont.supporting)
                            }
                        }
                    }
                    if let error = flow.errorMessage {
                        SUConfirmationBanner(title: String(localized: "Not saved"), message: error, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                    }
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.lg)
                .padding(.bottom, 120)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Final review"))
            .sensoryFeedback(.error, trigger: failureCount)
            .safeAreaInset(edge: .bottom) { actions(room) }
        }
    }

    private func header(_ summary: ReceiptRoomSummary) -> some View {
        let room = summary.room
        return SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Text(room.title).font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
                Text("\(room.receipt.date.value.formatted(date: .abbreviated, time: .omitted)) · \(summary.group?.name ?? "")")
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                SUAmountView(money: summary.total, style: .large)
                Label {
                    Text(ReceiptLanguage.finalStatement(room: room, allocation: summary.allocation, names: summary.names,
                                                        currentUserID: summary.currentUserID, locale: locale))
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(SUColor.positive)
                }
                .font(SUFont.supporting)
                .foregroundStyle(SUColor.textPrimary)
                .accessibilityIdentifier("final.statement")
            }
        }
    }

    /// Who hasn't reviewed their share yet: wait for them, go back to change something, or finalize
    /// for them — named one by one, and shown as host-resolved in the final record.
    private func unreviewedPanel(_ summary: ReceiptRoomSummary) -> some View {
        SUPanelSection(title: Inflect.string("^[\(unreviewed.count) person](inflect: true) hasn't reviewed their share"),
                       subtitle: String(localized: "Wait for them, change something, or finalize their share for them.")) {
            ForEach(unreviewed, id: \.self) { person in
                Toggle(isOn: Binding(get: { acknowledged.contains(person) }, set: { on in
                    if on { acknowledged.insert(person) } else { acknowledged.remove(person) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name(person)).font(SUFont.body.weight(.semibold))
                        Text(String(localized: "Finalize their \(MoneyFormatting.string(summary.allocation.participant(person).total, locale: locale)) for them"))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                }
                .accessibilityIdentifier("final.acknowledge.\(summary.members[person]?.firstName ?? "")")
            }
        }
        .accessibilityIdentifier("final.unreviewed")
    }

    private func actions(_ room: ReceiptRoom) -> some View {
        VStack(spacing: SUSpacing.xs) {
            if !waitingOn.isEmpty {
                Label(String(localized: "Waiting for reviews. Finalize for them above, or come back later."), systemImage: "hourglass")
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
            Button {
                finalize(room)
            } label: {
                Label(saveTitle, systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .disabled(isFinalizing || !waitingOn.isEmpty)
            .accessibilityIdentifier("final.save")
            Button(String(localized: "Back to room")) {
                Task { await flow.run(.transition(room.id, expectedRevision: room.revision, .returnToRoom), asHost: true) }
            }
            .buttonStyle(.suSecondary)
        }
        .padding(SUSpacing.md)
        .background(.bar)
    }

    private var saveTitle: String {
        if flow.remote?.isTemporary == true { return String(localized: "Finalize the split") }
        if flow.remote?.isGroupReceipt == true { return String(localized: "Save to the group") }
        return String(localized: "Save as expense")
    }

    /// Idempotent: a double tap sends the same command twice; the second is a no-op.
    private func finalize(_ room: ReceiptRoom) {
        isFinalizing = true
        let acknowledging = needsAcknowledgement ? unreviewed.filter(acknowledged.contains) : []
        Task {
            if await flow.run(.finalize(room.id, expectedRevision: room.revision, acknowledging: acknowledging), asHost: true) != nil {
                flow.environment.haptics.play(.settle)
            } else {
                failureCount += 1
            }
            isFinalizing = false
        }
    }
}

/// One person's items, charges, and final amount.
struct ParticipantBreakdown: View {
    let summary: ReceiptRoomSummary
    let participant: ParticipantTotal
    @Environment(\.locale) private var locale

    var body: some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                HStack(spacing: SUSpacing.sm) {
                    if let member = summary.members[participant.memberID] {
                        SUAvatar(member: member, size: .medium, isCurrentUser: member.id == summary.currentUserID)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.members[participant.memberID]?.displayName ?? "").font(SUFont.cardTitle)
                        if participant.memberID == summary.room.payerID {
                            SURoleBadge(kind: .payer)
                        }
                    }
                    Spacer()
                    SUAmountView(money: participant.total, style: .row)
                }
                ForEach(participant.itemShares, id: \.itemID) { share in
                    line(summary.room.receipt.item(share.itemID)?.name.value ?? "", share.amount)
                }
                if !participant.tax.isZero { line(String(localized: "Tax"), participant.tax) }
                if !participant.tip.isZero { line(String(localized: "Tip"), participant.tip) }
                if !participant.fees.isZero { line(String(localized: "Fees"), participant.fees) }
                if !participant.discounts.isZero { line(String(localized: "Discounts"), participant.discounts) }
                if !participant.adjustments.isZero { line(String(localized: "Adjustments"), participant.adjustments) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("final.participant.\(summary.members[participant.memberID]?.firstName ?? "")")
    }

    private func line(_ title: String, _ money: Money) -> some View {
        HStack {
            Text(title).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary).lineLimit(2)
            Spacer()
            Text(MoneyFormatting.signedString(money, locale: locale).replacingOccurrences(of: "+", with: ""))
                .font(SUFont.supporting.monospacedDigit()).foregroundStyle(SUColor.textPrimary)
        }
    }
}

/// Success after finalization: the strong confirmation is reserved for this moment (§13.4).
struct ReceiptSuccessView: View {
    let flow: ReceiptFlowModel
    let expenseID: ExpenseID
    let viewExpense: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SUMeshBackground(palette: .positive, isAnimated: flow.environment.allowsAmbientAnimation && !reduceMotion)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: SUSpacing.lg) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.drawOn, isActive: !appeared && !reduceMotion)
                    .accessibilityHidden(true)
                VStack(spacing: SUSpacing.xs) {
                    Text(String(localized: "Receipt saved"))
                        .font(SUFont.screenTitle)
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    if let room = flow.room, let total = room.receipt.total.value {
                        Text(String(localized: "\(room.title) · \(MoneyFormatting.string(total)) is now an itemized expense. Balances are updated."))
                            .font(SUFont.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                }
                VStack(spacing: SUSpacing.sm) {
                    Button(String(localized: "View expense"), action: viewExpense)
                        .buttonStyle(.suPrimary(fullWidth: true))
                        .accessibilityIdentifier("success.viewExpense")
                    Button(String(localized: "Done")) { dismiss() }
                        .buttonStyle(.suSecondary(fullWidth: true))
                }
                .frame(maxWidth: 420)
            }
            .padding(SUSpacing.xl)
        }
        .environment(\.colorScheme, .dark)
        .navigationBarBackButtonHidden()
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt.success")
    }
}
