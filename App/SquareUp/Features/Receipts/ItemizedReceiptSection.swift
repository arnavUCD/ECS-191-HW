import SwiftUI

/// On an itemized expense: the receipt, every item's shares, charges, each person's total, the
/// proof of equality, and the room's history (milestone 3 §9.4, §13.2 screen 13).
///
/// It shows the frozen allocation snapshot, so it explains the expense even after later edits.
struct ItemizedReceiptSection: View {
    let room: ReceiptRoom
    let expense: Expense
    let members: [MemberID: Member]
    let currentUserID: MemberID

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.locale) private var locale
    @State private var viewingPage: ReceiptAsset?
    @State private var showsHistory = false
    @State private var isConfirmingRemoval = false
    @State private var removalError: String?

    private var names: [MemberID: String] { PersonIdentity.shortLabels(for: Array(members.values)) }

    var body: some View {
        if let snapshot = room.finalSnapshot {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: String(localized: "Receipt"), subtitle: String(localized: "Who had what, as saved"))
                pages
                SUCard {
                    VStack(alignment: .leading, spacing: SUSpacing.sm) {
                        proof(snapshot)
                        if expense.revision > 1 {
                            Label(String(localized: "This expense was edited after it was finalized. The breakdown below is the receipt as finalized."),
                                  systemImage: "pencil")
                                .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                        }
                        Divider()
                        ForEach(snapshot.items, id: \.id) { item in itemRow(item) }
                        if !snapshot.charges.isEmpty { Divider() }
                        ForEach(snapshot.charges, id: \.id) { charge in chargeRow(charge) }
                        Divider()
                        ForEach(snapshot.participants.filter { !$0.total.isZero }, id: \.memberID) { participant in
                            totalRow(participant)
                        }
                        ForEach(snapshot.rounding, id: \.self) { note in
                            Label(ReceiptLanguage.rounding(note, receipt: room.receipt, names: names, locale: locale), systemImage: "info.circle")
                                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("expense.itemized")
                // A receipt one person assigned when adding it to a group never had a room to tell about.
                if !isAssignedByOnePerson { history }
            }
            .sheet(item: $viewingPage) { page in
                ReceiptPageSheet(pages: room.receipt.activePages, selected: page)
            }
            .confirmationDialog(String(localized: "Remove the receipt images?"), isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                Button(String(localized: "Remove images"), role: .destructive) { removeImages() }
            } message: {
                Text(String(localized: "The photos are deleted from this iPhone. The itemized breakdown and history stay with the expense."))
            }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var pages: some View {
        let active = room.receipt.activePages
        if active.isEmpty {
            Label(room.receipt.pages.isEmpty ? String(localized: "No receipt image was attached.") : String(localized: "Receipt images were removed."),
                  systemImage: "photo.badge.exclamationmark")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SUSpacing.sm) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, page in
                        Button { viewingPage = page } label: {
                            ReceiptImageView(asset: page, variant: .thumbnail, contentMode: .fill)
                                .frame(width: 96, height: 128)
                                .clipShape(SUShape.compact)
                        }
                        .buttonStyle(.suPressable)
                        .accessibilityLabel(String(localized: "Receipt page \(index + 1)"))
                        .accessibilityHint(String(localized: "Opens the full image"))
                        .accessibilityIdentifier("expense.receiptPage")
                    }
                }
            }
            if room.hostID == currentUserID {
                Button(String(localized: "Remove receipt images"), systemImage: "trash") { isConfirmingRemoval = true }
                    .font(SUFont.metadata.weight(.semibold))
                    .foregroundStyle(SUColor.negative)
                    .frame(minHeight: SUMetrics.minimumTouchTarget)
            }
            if let removalError {
                Text(removalError).font(SUFont.metadata).foregroundStyle(SUColor.negative)
            }
        }
    }

    private func proof(_ snapshot: ReceiptAllocationSnapshot) -> some View {
        let sum = snapshot.participants.map(\.total).sum(in: snapshot.total.currency)
        return Label {
            Text(sum == snapshot.total
                ? String(localized: "Everyone's shares add up to \(MoneyFormatting.string(sum, locale: locale)), exactly the receipt total.")
                : String(localized: "Shares add up to \(MoneyFormatting.string(sum, locale: locale)); the receipt total is \(MoneyFormatting.string(snapshot.total, locale: locale))."))
        } icon: {
            Image(systemName: sum == snapshot.total ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(sum == snapshot.total ? SUColor.positive : SUColor.warning)
        }
        .font(SUFont.supporting)
        .accessibilityIdentifier("expense.itemizedProof")
    }

    private func itemRow(_ item: ReceiptAllocationSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.quantity.map { "\($0)× \(item.name)" } ?? item.name).font(SUFont.body).lineLimit(3)
                Spacer()
                Text(MoneyFormatting.signedString(item.lineTotal, locale: locale).replacingOccurrences(of: "+", with: "")).font(SUFont.body.monospacedDigit())
            }
            Text(sharesText(item.shares, isNote: item.lineTotal.isZero))
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chargeRow(_ charge: ReceiptAllocationSnapshot.Charge) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Label(charge.label, systemImage: ReceiptLanguage.symbol(charge.kind)).font(SUFont.body)
                Spacer()
                Text(MoneyFormatting.signedString(charge.amount, locale: locale).replacingOccurrences(of: "+", with: "")).font(SUFont.body.monospacedDigit())
            }
            // "Add to a group" saves charges as exact cents worked out in proportion; say what they mean.
            Text("\(ReceiptLanguage.name(isAssignedByOnePerson && charge.allocation.kind == .exact ? .proportional : charge.allocation.kind)) · \(sharesText(charge.shares, isNote: false))")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func totalRow(_ participant: ParticipantTotal) -> some View {
        HStack(spacing: SUSpacing.sm) {
            if let member = members[participant.memberID] {
                SUAvatar(member: member, size: .small, isCurrentUser: member.id == currentUserID)
            }
            Text(participant.memberID == currentUserID ? String(localized: "You") : names[participant.memberID] ?? "")
                .font(SUFont.body.weight(.semibold))
            Spacer()
            SUAmountView(money: participant.total, style: .row)
        }
        .accessibilityElement(children: .combine)
    }

    /// Everything was done by the person who added it ("Add to a group"): nobody else took part.
    private var isAssignedByOnePerson: Bool { room.history.allSatisfy { $0.actorID == room.hostID } }

    private var history: some View {
        DisclosureGroup(isExpanded: $showsHistory) {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                ForEach(room.history, id: \.sequence) { event in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ReceiptLanguage.history(event, room: room, names: names, locale: locale)).font(SUFont.supporting)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, SUSpacing.xs)
        } label: {
            Text(Inflect.string("Receipt history · ^[\(room.history.count) event](inflect: true)"))
                .font(SUFont.supporting.weight(.semibold))
        }
        .padding(SUSpacing.md)
        .suSurface(SUShape.card)
        .accessibilityIdentifier("expense.roomHistory")
    }

    private func sharesText(_ shares: [Share], isNote: Bool) -> String {
        if isNote { return String(localized: "Note · not split") }
        return shares.map { share in
            let who = share.memberID == currentUserID ? String(localized: "you") : names[share.memberID] ?? ""
            return "\(who) \(MoneyFormatting.signedString(share.amount, locale: locale).replacingOccurrences(of: "+", with: ""))"
        }.joined(separator: " · ")
    }

    private func removeImages() {
        Task {
            do {
                try await environment.ledger.run(.markImagesRemoved(room.id), as: nil)
                await environment.receipts.assets.delete(room.receipt.pages)
                removalError = nil
            } catch {
                removalError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
            }
        }
    }
}

/// Full receipt pages with zoom (receipt viewer).
struct ReceiptPageSheet: View {
    let pages: [ReceiptAsset]
    @State var selected: ReceiptAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selected) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    ReceiptEvidenceViewer(page: page, accessibilityDescription: String(localized: "Page \(index + 1) of \(pages.count)"))
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .background(SUColor.backgroundPrimary)
            .navigationTitle(String(localized: "Receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
    }
}
