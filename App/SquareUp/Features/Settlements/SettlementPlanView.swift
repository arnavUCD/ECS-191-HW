import SwiftUI

/// Everything the plan screen shows, derived from one snapshot.
nonisolated struct SettlementPlanSummary: Equatable, Sendable {
    let group: ExpenseGroup
    let plan: SettlementPlan
    let members: [MemberID: Member]
    let currentUserID: MemberID
    /// Enabled destinations by recipient, preferred first.
    let destinations: [MemberID: [PaymentDestination]]
    /// Unfinished drafts the current user started (handoff opened, not yet reported).
    let myDrafts: [PaymentAttempt]

    static func make(groupID: GroupID, from snapshot: LedgerSnapshot) throws -> SettlementPlanSummary {
        guard let group = snapshot.group(groupID) else { throw LedgerError.groupNotFound }
        let plan = SettlementPlanner.plan(for: group, expenses: snapshot.expenses(in: groupID),
                                          settlements: snapshot.settlements(in: groupID), attempts: snapshot.attempts(in: groupID))
        var destinations: [MemberID: [PaymentDestination]] = [:]
        for id in group.memberIDs {
            destinations[id] = snapshot.destinations(of: id).filter(\.isEnabled)
        }
        return SettlementPlanSummary(
            group: group, plan: plan, members: snapshot.members, currentUserID: snapshot.currentUserID,
            destinations: destinations,
            myDrafts: snapshot.attempts(in: groupID).filter { $0.state.isDraft && $0.payerID == snapshot.currentUserID }
        )
    }

    /// Payments for the current user first, then everyone else's.
    var orderedPayments: [PlannedPayment] {
        let mine = plan.payments.filter { $0.payerID == currentUserID }
        let toMe = plan.payments.filter { $0.recipientID == currentUserID }
        let others = plan.payments.filter { $0.payerID != currentUserID && $0.recipientID != currentUserID }
        return mine + toMe + others
    }
}

/// The optimized settlement plan (milestone 2 §9): who pays whom, in plain language, with the
/// before/after count, pending payments held out, and a way to start each of your payments.
struct SettlementPlanView: View {
    let groupID: GroupID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettlementPlanScreen(groupID: groupID, environment: environment)
    }
}

private struct SettlementPlanScreen: View {
    let groupID: GroupID
    let environment: AppEnvironment
    @State private var model: SnapshotModel<SettlementPlanSummary>
    @State private var toggleError: String?
    @Environment(AppRouter.self) private var router

    init(groupID: GroupID, environment: AppEnvironment) {
        self.groupID = groupID
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger) { try SettlementPlanSummary.make(groupID: groupID, from: $0) })
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "Settle up"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: environment.ledger.revision) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { SULoadingState(cardCount: 3).padding(SUSpacing.screenMargin) }.suScreenBackground()
        case .failed(let error):
            SUErrorState(title: String(localized: "Couldn't load the plan"), message: LedgerErrorMessages.text(for: error)) {
                Task { await model.load() }
            }
            .frame(maxHeight: .infinity)
            .suScreenBackground()
        case .loaded(let summary):
            loaded(summary)
        }
    }

    private func loaded(_ summary: SettlementPlanSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                header(summary)
                if !summary.plan.pending.isEmpty {
                    pendingSection(summary)
                }
                if summary.plan.payments.isEmpty {
                    if summary.plan.pending.isEmpty {
                        SUEmptyState(
                            systemImage: "checkmark.seal.fill",
                            title: String(localized: "Everyone is square"),
                            message: String(localized: "Nobody in \(summary.group.name) owes anything right now.")
                        )
                    }
                } else {
                    paymentsSection(summary)
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xxl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
    }

    private func header(_ summary: SettlementPlanSummary) -> some View {
        let plan = summary.plan
        let people = summary.group.activeMemberIDs.compactMap { summary.members[$0] }
        return SUCoverPanel(palette: .calm, symbol: summary.group.symbolName, coverHeight: 170) {
            planChip(plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SUAvatarCluster(members: people, currentUserID: summary.currentUserID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            SUTagPill(title: plan.isSimplified ? String(localized: "Simplified") : String(localized: "Direct"),
                      systemImage: plan.isSimplified ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.left.arrow.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        } content: {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.group.name).font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
                    Text(PlanLanguage.countSummary(summary.plan))
                        .font(SUFont.supporting)
                        .foregroundStyle(SUColor.textSecondary)
                        .accessibilityIdentifier("plan.count")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: Binding(
                    get: { summary.group.simplifiesDebts },
                    set: { enabled in
                        Task {
                            do {
                                try await environment.ledger.setSimplification(enabled, for: summary.group.id)
                                toggleError = nil
                            } catch {
                                toggleError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
                            }
                        }
                    }
                )) {
                    Text(String(localized: "Simplify payments")).font(SUFont.body)
                }
                .tint(SUColor.accent)
                .accessibilityIdentifier("plan.simplify")
                Text(String(localized: """
                Simplifying changes who pays whom, not how much anyone owes or is owed overall. \
                Square Up never moves money — each payment happens in the app you choose.
                """))
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                if let toggleError {
                    Label(toggleError, systemImage: "exclamationmark.circle").font(SUFont.metadata).foregroundStyle(SUColor.negative)
                }
            }
        }
    }

    /// The readout on the plan's cover: payments left, and how many simplifying saved.
    private func planChip(_ plan: SettlementPlan) -> SUCoverChip {
        if plan.payments.isEmpty {
            return SUCoverChip(lead: .readout("\(plan.pending.count)"), title: String(localized: "Payments"),
                               subtitle: plan.pending.isEmpty ? String(localized: "Everyone's square") : String(localized: "awaiting confirmation"))
        }
        let count = plan.payments.count
        let saved = plan.isSimplified && plan.simplifiedPaymentCount < plan.directPaymentCount
        return SUCoverChip(lead: .readout("\(count)"), title: count == 1 ? String(localized: "Payment") : String(localized: "Payments"),
                           subtitle: saved ? String(localized: "instead of \(plan.directPaymentCount)") : String(localized: "to settle up"))
    }

    private func paymentsSection(_ summary: SettlementPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Payments"))
            VStack(spacing: SUSpacing.xs) {
                ForEach(summary.orderedPayments) { payment in
                    PlannedPaymentCard(summary: summary, payment: payment) {
                        router.push(.pay(groupID: summary.group.id, recipientID: payment.recipientID))
                    }
                }
            }
        }
    }

    private func pendingSection(_ summary: SettlementPlanSummary) -> some View {
        SUPanelSection(
            title: String(localized: "Awaiting confirmation"),
            subtitle: String(localized: "Reported as sent. Not counted as paid until the recipient confirms.")
        ) {
            VStack(spacing: 0) {
                ForEach(summary.plan.pending) { attempt in
                    Button {
                        router.push(.paymentAttempt(attempt.id))
                    } label: {
                        PendingAttemptRow(attempt: attempt, members: summary.members, currentUserID: summary.currentUserID)
                    }
                    .buttonStyle(.plain)
                    if attempt.id != summary.plan.pending.last?.id { Divider().overlay(SUColor.hairline).padding(.leading, 52) }
                }
            }
        }
    }
}

/// One recommended payment with both identities visible.
private struct PlannedPaymentCard: View {
    let summary: SettlementPlanSummary
    let payment: PlannedPayment
    let pay: () -> Void

    var body: some View {
        let payer = summary.members[payment.payerID]
        let recipient = summary.members[payment.recipientID]
        let isMine = payment.payerID == summary.currentUserID
        return SUCard(padding: SUSpacing.md) {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                HStack(alignment: .top, spacing: SUSpacing.sm) {
                    if let payer, let recipient {
                        SUTransferMark(payer: payer, recipient: recipient, currentUserID: summary.currentUserID, showsNames: true)
                    }
                    Spacer(minLength: SUSpacing.xs)
                    SUAmountView(money: payment.amount, direction: isMine ? .outgoing : .neutral, style: .large, emphasizesWholeUnits: true)
                        .padding(.top, SUSpacing.xs)
                }
                Text(PlanLanguage.sentence(for: payment, members: summary.members, currentUserID: summary.currentUserID))
                    .font(SUFont.body.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                Text(PlanLanguage.acceptedMethods(summary.destinations[payment.recipientID] ?? []))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                if isMine {
                    Button(action: pay) {
                        Text(String(localized: "Pay \(recipient?.firstName ?? "")"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.suPrimary)
                    .accessibilityIdentifier("plan.pay.\(recipient?.firstName ?? "")")
                    .accessibilityHint(String(localized: "Choose how to pay. Nothing is paid until you send it in another app."))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.payment")
    }
}

/// A reported or disputed payment, held out of the plan.
struct PendingAttemptRow: View {
    let attempt: PaymentAttempt
    let members: [MemberID: Member]
    let currentUserID: MemberID

    var body: some View {
        HStack(spacing: SUSpacing.sm) {
            if let payer = members[attempt.payerID] {
                SUAvatar(member: payer, size: .medium, isCurrentUser: payer.id == currentUserID)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(PaymentStatusLanguage.headline(for: attempt, members: members, currentUserID: currentUserID))
                    .font(SUFont.body.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                PaymentStateChip(state: attempt.state)
            }
            Spacer(minLength: SUSpacing.xs)
            SUAmountView(money: attempt.amount, direction: .muted, style: .row)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SUSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
