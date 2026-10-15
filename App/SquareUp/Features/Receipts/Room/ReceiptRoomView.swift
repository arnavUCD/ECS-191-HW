import SwiftUI

/// The Live Receipt Room (milestone 3 §8, §13.3). Three facts are always obvious: who is acting,
/// what they have claimed and owe, and what remains unresolved.
struct ReceiptRoomView: View {
    let flow: ReceiptFlowModel
    @State private var filter: RoomFilter = .all
    @State private var splittingItem: ReceiptItemID?
    /// "How many did you have?" for a line with a printed quantity.
    @State private var countingItem: ReceiptItemID?
    @State private var allocatingCharge: ReceiptChargeID?
    @State private var disputeTarget: DisputeTargetSelection?
    @State private var resolvingDispute: ReceiptDisputeID?
    @State private var isEditingParticipants = false
    @State private var isEditingReceipt = false
    @State private var isConfirmingCancel = false
    @State private var claimCount = 0
    @State private var warningCount = 0
    @State private var reconciledCount = 0
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let room = flow.room, let snapshot = flow.snapshot, let actor = flow.actor {
            let summary = ReceiptRoomSummary.make(room: room, snapshot: snapshot, actorID: actor)
            content(summary)
                .onChange(of: summary.remaining.isZero) { _, isZero in
                    if isZero, summary.allocation.isComplete {
                        reconciledCount += 1
                        flow.environment.haptics.play(.reconcile)
                    }
                }
        }
    }

    private func content(_ summary: ReceiptRoomSummary) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let error = flow.errorMessage {
                    SUConfirmationBanner(title: String(localized: "Not changed"), message: error, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                        .accessibilityIdentifier("room.error")
                }
                if summary.needsYourReview {
                    SUConfirmationBanner(title: String(localized: "An item you claimed changed"),
                                         message: String(localized: "The host edited the receipt. Check your items, then mark your portion reviewed."),
                                         systemImage: "arrow.triangle.2.circlepath", tone: .warning)
                }
                YourTotalCard(summary: summary) { markReviewed(summary) }
                RoomProgressCard(summary: summary)
                disputesSection(summary)
                filters(summary)
                itemsList(summary)
                chargesSection(summary)
                // A receipt in a group is split asynchronously in that group, never as a live room with
                // invitations; splitting live is "Split with people now", chosen after review.
                if summary.isActorHost { hostTools(summary) }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.top, SUSpacing.sm)
            .padding(.bottom, 140)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(summary.room.title)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Who is acting is always visible (§13.3), never scrolled away. A shared room shows
            // `SharedRoomStatusBar` instead: there, everyone acts on their own device.
            if flow.remote == nil {
                IdentitySwitcher(summary: summary, selection: Binding(get: { flow.actor }, set: { flow.actingMemberID = $0 }))
            }
        }
        .environment(\.pendingRoomItems, flow.remote?.pendingItemIDs ?? [])
        .safeAreaInset(edge: .bottom) { bottomBar(summary) }
        .sensoryFeedback(.selection, trigger: claimCount)
        .sensoryFeedback(.warning, trigger: warningCount)
        .sheet(item: Binding(get: { splittingItem.map(ItemRef.init) }, set: { splittingItem = $0?.id })) { ref in
            SharedItemEditor(flow: flow, summary: summary, itemID: ref.id)
        }
        .sheet(item: Binding(get: { countingItem.map(ItemRef.init) }, set: { countingItem = $0?.id })) { ref in
            UnitsClaimSheet(flow: flow, summary: summary, itemID: ref.id)
        }
        .sheet(item: Binding(get: { allocatingCharge.map(ChargeRef.init) }, set: { allocatingCharge = $0?.id })) { ref in
            ChargeAllocationEditor(flow: flow, summary: summary, chargeID: ref.id)
        }
        .sheet(item: $disputeTarget) { selection in
            DisputeEditor(flow: flow, summary: summary, target: selection.target)
        }
        .sheet(item: Binding(get: { resolvingDispute.map(DisputeRef.init) }, set: { resolvingDispute = $0?.id })) { ref in
            DisputeResolutionView(flow: flow, summary: summary, disputeID: ref.id) { itemID in
                resolvingDispute = nil
                splittingItem = itemID
            }
        }
        .sheet(isPresented: $isEditingParticipants) { ParticipantsEditor(flow: flow, summary: summary) }
        .sheet(isPresented: $isEditingReceipt) {
            if let snapshot = flow.snapshot {
                RoomReceiptEditor(flow: flow, review: ReceiptReviewModel(room: summary.room, snapshot: snapshot, now: flow.environment.now))
            }
        }
        .confirmationDialog(String(localized: "Close this room?"), isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button(String(localized: "Close room"), role: .destructive) {
                Task { await flow.run(.cancel(summary.room.id, expectedRevision: summary.room.revision), asHost: true) }
            }
        } message: {
            Text(String(localized: "No expense will be created. Claims are kept in the room's history."))
        }
    }

    // MARK: Items

    private func filters(_ summary: ReceiptRoomSummary) -> some View {
        GlassEffectContainer(spacing: SUSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SUSpacing.xs) {
                    ForEach(RoomFilter.allCases) { option in
                        Button {
                            filter = option
                        } label: {
                            Text("\(option.title) \(summary.count(option))")
                                .font(SUFont.chip)
                                .padding(.horizontal, SUSpacing.sm)
                                .frame(minHeight: 36)
                                .foregroundStyle(filter == option ? Color.black : SUColor.textPrimary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(filter == option ? .regular.tint(.white).interactive() : .regular.interactive(), in: Capsule())
                        .accessibilityLabel(String(localized: "\(option.title), \(summary.count(option)) items"))
                        .accessibilityAddTraits(filter == option ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("room.filter.\(option.rawValue)")
                    }
                }
            }
        }
    }

    private func itemsList(_ summary: ReceiptRoomSummary) -> some View {
        let lines = summary.lines(for: filter)
        return VStack(alignment: .leading, spacing: SUSpacing.xs) {
            SUSectionHeader(title: String(localized: "Items"))
            if lines.isEmpty {
                Text(String(localized: "Nothing here."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    .padding(SUSpacing.md)
            }
            ForEach(lines) { line in
                RoomItemRow(summary: summary, line: line, actions: actions(for: line, summary))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: summary.lines)
    }

    private func actions(for line: ReceiptRoomSummary.ItemLine, _ summary: ReceiptRoomSummary) -> RoomItemRow.Actions {
        RoomItemRow.Actions(
            mine: { claim(line, .mine, summary) },
            share: { claim(line, .share, summary) },
            undo: { unclaim(line, summary) },
            customSplit: { splittingItem = line.id },
            dispute: { disputeTarget = DisputeTargetSelection(target: .item(line.id)) },
            resolve: line.openDisputes.first.map { dispute in { resolvingDispute = dispute.id } },
            units: { countingItem = line.id }
        )
    }

    // MARK: Charges and disputes

    private func chargesSection(_ summary: ReceiptRoomSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            if !summary.room.receipt.charges.isEmpty {
                SUSectionHeader(title: String(localized: "Tax, tip & extras"), subtitle: summary.isActorHost
                    ? String(localized: "Tap to choose how each is divided.") : String(localized: "The host chooses how these are divided."))
            }
            ForEach(summary.room.receipt.charges) { charge in
                ChargeRow(summary: summary, charge: charge) {
                    if summary.isActorHost { allocatingCharge = charge.id } else { disputeTarget = DisputeTargetSelection(target: .charge(charge.id)) }
                }
            }
        }
    }

    @ViewBuilder
    private func disputesSection(_ summary: ReceiptRoomSummary) -> some View {
        let open = summary.room.openDisputes
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUSectionHeader(title: String(localized: "Disputes"), subtitle: String(localized: "Must be resolved before saving."))
                ForEach(open) { dispute in
                    DisputeRow(summary: summary, dispute: dispute, canResolve: summary.isActorHost) { resolvingDispute = dispute.id }
                }
            }
        }
    }

    private func hostTools(_ summary: ReceiptRoomSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            SUSectionHeader(title: String(localized: "Host tools"))
            SUCard(padding: SUSpacing.xs) {
                VStack(spacing: 0) {
                    if summary.room.state == .open {
                        toolButton(String(localized: "Lock claims and resolve the rest"), "lock") { transition(.beginResolving, summary) }
                    } else if summary.room.state == .resolving {
                        toolButton(String(localized: "Reopen claims"), "lock.open") { transition(.reopenClaims, summary) }
                    }
                    toolButton(String(localized: "Edit receipt"), "square.and.pencil") { isEditingReceipt = true }
                    if flow.remote == nil {
                        // Shared rooms grow by invitation; seats come from the group when sharing.
                        toolButton(String(localized: "Who's in the room"), "person.2") { isEditingParticipants = true }
                    }
                    toolButton(String(localized: "Close room without saving"), "xmark.circle", role: .destructive) { isConfirmingCancel = true }
                }
            }
        }
    }

    private func toolButton(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: SUMetrics.minimumTouchTarget, alignment: .leading)
                .padding(.horizontal, SUSpacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? SUColor.negative : SUColor.textPrimary)
    }

    // MARK: Bottom bar

    private func bottomBar(_ summary: ReceiptRoomSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            if summary.isActorHost {
                if let first = summary.readiness.first {
                    Label(summary.readiness.count > 1
                        ? String(localized: "\(ReceiptLanguage.readiness(first, room: summary.room, names: summary.names, locale: locale)) +\(summary.readiness.count - 1) more")
                        : ReceiptLanguage.readiness(first, room: summary.room, names: summary.names, locale: locale),
                        systemImage: "exclamationmark.circle")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        .accessibilityIdentifier("room.readiness")
                }
                if summary.readiness == [.onlyPayerOwes] {
                    Button(String(localized: "Yes, the payer keeps the whole receipt")) {
                        Task { await flow.run(.setPayerAcceptsFullReceipt(summary.room.id, expectedRevision: summary.room.revision, true), asHost: true) }
                    }
                    .buttonStyle(.suSecondary)
                }
                Button {
                    transition(.requestFinalReview, summary)
                } label: {
                    Label(String(localized: "Review & finalize"), systemImage: "checklist").frame(maxWidth: .infinity)
                }
                .buttonStyle(.suPrimary)
                .disabled(!summary.readiness.isEmpty)
                .accessibilityIdentifier("room.finalReview")
            } else if let remote = flow.remote {
                Text(participantNote(summary, remote: remote))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    .accessibilityIdentifier("room.participantNote")
            } else {
                Text(String(localized: "Only \(summary.name(summary.room.hostID)) (host) can finalize. Switch to them to finish."))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
        }
        .padding(SUSpacing.md)
        .background(.bar)
    }

    /// What happens next, for someone who isn't hosting.
    private func participantNote(_ summary: ReceiptRoomSummary, remote: RemoteRoomLedger) -> String {
        let host = summary.name(summary.room.hostID)
        if summary.room.state == .readyToFinalize { return String(localized: "\(host) is doing the final review. Claims are locked.") }
        if remote.isGroupReceipt {
            return String(localized: "Claim what you had and mark your share reviewed. \(host) finishes it into a group expense; balances don't change until then.")
        }
        if remote.isTemporary {
            return String(localized: "Claim what you had, then mark your share reviewed. When \(host) finalizes, you'll see what to pay them.")
        }
        return String(localized: "\(host) (host) saves the split when everything is claimed.")
    }

    // MARK: Commands

    private func claim(_ line: ReceiptRoomSummary.ItemLine, _ request: ClaimRequest, _ summary: ReceiptRoomSummary) {
        Task {
            let before = summary.you.total
            if await flow.runInSequence({ .claim($0.id, expectedRevision: $0.revision, item: line.id, request) }) != nil {
                claimCount += 1
                announceTotal(previous: before)
            } else {
                warningCount += 1
            }
        }
    }

    private func unclaim(_ line: ReceiptRoomSummary.ItemLine, _ summary: ReceiptRoomSummary) {
        Task {
            let before = summary.you.total
            if await flow.runInSequence({ .unclaim($0.id, expectedRevision: $0.revision, item: line.id) }) != nil {
                claimCount += 1
                announceTotal(previous: before)
            } else {
                warningCount += 1
            }
        }
    }

    private func transition(_ move: ReceiptRoomTransition, _ summary: ReceiptRoomSummary) {
        Task {
            if await flow.run(.transition(summary.room.id, expectedRevision: summary.room.revision, move), asHost: true) == nil { warningCount += 1 }
        }
    }

    private func markReviewed(_ summary: ReceiptRoomSummary) {
        Task { await flow.run(.markReviewed(summary.room.id, expectedRevision: summary.room.revision)) }
    }

    /// §13.5 "Announce when a claim changes a participant total."
    private func announceTotal(previous: Money) {
        guard let room = flow.room, let snapshot = flow.snapshot, let actor = flow.actor else { return }
        let now = ReceiptAllocationEngine.allocate(room).participant(actor).total
        guard now != previous else { return }
        let name = snapshot.members[actor]?.firstName ?? ""
        AccessibilityNotification.Announcement(
            String(localized: "\(name)'s total is now \(MoneyFormatting.spokenString(now, locale: locale))")
        ).post()
    }
}

struct DisputeTargetSelection: Identifiable, Hashable {
    let target: DisputeTarget
    var id: String { "\(target)" }
}

private struct ItemRef: Identifiable {
    let id: ReceiptItemID
}

private struct ChargeRef: Identifiable {
    let id: ReceiptChargeID
}

private struct DisputeRef: Identifiable {
    let id: ReceiptDisputeID
}
