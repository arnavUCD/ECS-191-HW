import SwiftUI

nonisolated struct PaymentAttemptSummary: Equatable, Sendable {
    let attempt: PaymentAttempt
    let group: ExpenseGroup
    let members: [MemberID: Member]
    let currentUserID: MemberID
    let settlement: Settlement?
    /// Whether the whole group is square (nothing to pay, nothing pending).
    let isGroupSettled: Bool

    static func make(attemptID: PaymentAttemptID, from snapshot: LedgerSnapshot) throws -> PaymentAttemptSummary {
        guard let attempt = snapshot.attempt(attemptID) else { throw LedgerError.rule(.attemptNotFound) }
        guard let group = snapshot.group(attempt.groupID) else { throw LedgerError.groupNotFound }
        let plan = SettlementPlanner.plan(for: group, expenses: snapshot.expenses(in: group.id),
                                          settlements: snapshot.settlements(in: group.id), attempts: snapshot.attempts(in: group.id))
        return PaymentAttemptSummary(
            attempt: attempt, group: group, members: snapshot.members, currentUserID: snapshot.currentUserID,
            settlement: attempt.settlementID.flatMap { id in snapshot.settlements.first { $0.id == id } },
            isGroupSettled: plan.isSettled
        )
    }

    var isPayer: Bool { attempt.payerID == currentUserID }
    var isRecipient: Bool { attempt.recipientID == currentUserID }
    var payer: Member? { members[attempt.payerID] }
    var recipient: Member? { members[attempt.recipientID] }
}

/// One payment's status, timeline, and the actions available to whoever is looking.
struct PaymentAttemptView: View {
    let attemptID: PaymentAttemptID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        PaymentAttemptScreen(attemptID: attemptID, environment: environment)
    }
}

private struct PaymentAttemptScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<PaymentAttemptSummary>
    @State private var success: PaymentSuccess?
    @State private var actionError: String?
    @State private var isActingAsRecipient = false
    @Environment(AppRouter.self) private var router

    init(attemptID: PaymentAttemptID, environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger) { try PaymentAttemptSummary.make(attemptID: attemptID, from: $0) })
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "Payment"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: environment.ledger.revision) { await model.load() }
            .sharedGroupSync(environment.sharedGroup)
            .fullScreenCover(item: $success) { success in
                SettlementSuccessView(success: success)
            }
            .sheet(isPresented: $isActingAsRecipient) {
                if let summary = model.value {
                    SampleRecipientSheet(summary: summary) { confirmed in
                        isActingAsRecipient = false
                        if confirmed { celebrate(summary) }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).suScreenBackground()
        case .failed(let error):
            SUErrorState(title: String(localized: "Couldn't load this payment"), message: LedgerErrorMessages.text(for: error)) {
                Task { await model.load() }
            }
            .frame(maxHeight: .infinity)
            .suScreenBackground()
        case .loaded(let summary):
            loaded(summary)
        }
    }

    private func loaded(_ summary: PaymentAttemptSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                header(summary)
                if let actionError {
                    SUConfirmationBanner(title: String(localized: "Not changed"), message: actionError,
                                         systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                actions(summary)
                timeline(summary)
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xxl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
    }

    /// The payment in one card: who paid whom and how, what it's for, then its state and amount.
    private func header(_ summary: PaymentAttemptSummary) -> some View {
        let attempt = summary.attempt
        return SUCard(padding: SUSpacing.md + 2) {
            VStack(alignment: .leading, spacing: SUSpacing.md) {
                HStack(alignment: .center) {
                    if let payer = summary.payer, let recipient = summary.recipient {
                        SUTransferMark(payer: payer, recipient: recipient, currentUserID: summary.currentUserID)
                    }
                    Spacer(minLength: SUSpacing.xs)
                    SUTagPill(title: attempt.provider.displayName, systemImage: attempt.provider.symbolName)
                }
                VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                    Text(PaymentStatusLanguage.headline(for: attempt, members: summary.members, currentUserID: summary.currentUserID))
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(SUColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("attempt.headline")
                    Text("\(summary.group.name) · \(attempt.reference)")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Divider().overlay(SUColor.hairline)
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    PaymentStateChip(state: attempt.state)
                        .accessibilityIdentifier("attempt.state")
                    SUAmountView(money: attempt.amount, style: .hero, emphasizesWholeUnits: true)
                    if let reference = attempt.externalReference {
                        Text(String(localized: "Payer's reference: \(reference) (not verified by Square Up)"))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(_ summary: PaymentAttemptSummary) -> some View {
        let attempt = summary.attempt
        let recipientName = summary.recipient?.firstName ?? ""
        if summary.isRecipient, attempt.state.reservesObligation {
            RecipientConfirmationCard(attempt: attempt, members: summary.members, actor: summary.currentUserID) { confirmed, error in
                actionError = error
                if confirmed { celebrate(summary) }
            }
        } else if summary.isPayer {
            switch attempt.state {
            case .methodSelected, .handoffOpened:
                SUConfirmationBanner(title: String(localized: "Not reported yet"),
                                     message: String(localized: "Nothing has been recorded. Finish paying, then report it."),
                                     systemImage: "arrow.uturn.forward.circle", tone: .informational)
                Button(String(localized: "Continue paying \(recipientName)")) {
                    router.push(.pay(groupID: attempt.groupID, recipientID: attempt.recipientID))
                }
                .buttonStyle(.suPrimary)
                cancelButton(attempt, title: String(localized: "Cancel attempt"))
            case .reportedSent:
                SUConfirmationBanner(
                    title: String(localized: "Waiting for \(recipientName) to confirm"),
                    message: String(localized: "It's held out of new suggestions so you won't be asked to pay twice. It counts as paid once \(recipientName) confirms."),
                    systemImage: "hourglass", tone: .warning
                )
                cancelButton(attempt, title: String(localized: "I didn't send it — cancel report"))
                sampleIdentityCard(summary)
            case .disputed:
                SUConfirmationBanner(
                    title: String(localized: "Disputed"),
                    message: String(localized: "Talk with \(recipientName). Neither of you is marked as settled until \(recipientName) confirms or rejects it."),
                    systemImage: "exclamationmark.bubble", tone: .warning
                )
                sampleIdentityCard(summary)
            case .rejected:
                SUConfirmationBanner(
                    title: String(localized: "\(recipientName) didn't receive it"),
                    message: String(localized: "\(MoneyFormatting.string(attempt.amount)) is owed again. Check with \(recipientName) before paying again."),
                    systemImage: "xmark.octagon", tone: .negative
                )
                Button(String(localized: "Pay \(recipientName) again")) {
                    router.push(.pay(groupID: attempt.groupID, recipientID: attempt.recipientID))
                }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("attempt.payAgain")
            case .confirmed:
                confirmedCard(summary)
            case .cancelled:
                SUConfirmationBanner(title: String(localized: "Cancelled"), message: String(localized: "No money was recorded."),
                                     systemImage: "xmark.circle", tone: .neutral)
            }
        } else if attempt.state == .confirmed {
            confirmedCard(summary)
        }
    }

    private func confirmedCard(_ summary: PaymentAttemptSummary) -> some View {
        SUConfirmationBanner(
            title: String(localized: "Confirmed by \(summary.recipient?.firstName ?? "")"),
            message: summary.isGroupSettled
                ? String(localized: "Everyone in \(summary.group.name) is square.")
                : String(localized: "This payment is part of the group's balances now."),
            systemImage: "checkmark.seal.fill", tone: .positive
        )
        .accessibilityIdentifier("attempt.confirmed")
    }

    private func cancelButton(_ attempt: PaymentAttempt, title: String) -> some View {
        Button(title, role: .destructive) {
            Task {
                do {
                    try await environment.ledger.advance(attempt.id, .cancel(.payerCancelled))
                    actionError = nil
                } catch {
                    actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
                }
            }
        }
        .buttonStyle(.suDestructive)
        .accessibilityIdentifier("attempt.cancel")
    }

    /// PROTOTYPE: let one device play the recipient's part, clearly labelled as local.
    private func sampleIdentityCard(_ summary: PaymentAttemptSummary) -> some View {
        let name = summary.recipient?.firstName ?? ""
        return SUCard(style: .elevated) {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Label(String(localized: "Local prototype"), systemImage: "iphone")
                    .font(SUFont.chip).foregroundStyle(SUColor.violet)
                Text(String(localized: "In the shared version, \(name) confirms on their own iPhone. In this prototype everyone is on this device, so you can respond as \(name) to try the flow. No message is sent to anyone."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                Button(String(localized: "Respond as \(name) (sample identity)")) { isActingAsRecipient = true }
                    .buttonStyle(.suSecondary)
                    .accessibilityIdentifier("attempt.respondAsRecipient")
            }
        }
    }

    private func timeline(_ summary: PaymentAttemptSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Timeline"))
            SUCard(padding: SUSpacing.sm + 2) {
                VStack(alignment: .leading, spacing: SUSpacing.sm) {
                    ForEach(Array(summary.attempt.history.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: SUSpacing.sm) {
                            Image(systemName: PaymentStatusLanguage.symbol(for: step.state))
                                .foregroundStyle(step.state.tone.color).frame(width: 24).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PaymentStatusLanguage.timelineLabel(for: step.state, provider: summary.attempt.provider))
                                    .font(SUFont.supporting.weight(.semibold))
                                Text(String(localized: "\(actorName(step.actorID, summary)) · \(step.date.formatted(date: .abbreviated, time: .shortened))"))
                                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                                if let note = step.note, step.state != .cancelled {
                                    Text(note).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func actorName(_ id: MemberID, _ summary: PaymentAttemptSummary) -> String {
        id == summary.currentUserID ? String(localized: "You") : (summary.members[id]?.displayName ?? "")
    }

    private func celebrate(_ summary: PaymentAttemptSummary) {
        Task {
            // Reload so the success screen reflects the confirmed ledger.
            await model.load()
            let updated = model.value ?? summary
            environment.haptics.play(.settle)
            success = PaymentSuccess(
                attempt: updated.attempt, payerName: updated.payer?.firstName ?? "", recipientName: updated.recipient?.firstName ?? "",
                groupName: updated.group.name, isGroupSettled: updated.isGroupSettled
            )
        }
    }
}

/// Recipient prompt (milestone 2 §13): Confirm received / Not received / Review later, plus
/// dispute. Text buttons, separated, never adjacent icon-only actions.
struct RecipientConfirmationCard: View {
    let attempt: PaymentAttempt
    let members: [MemberID: Member]
    /// Who is answering — the recipient.
    let actor: MemberID
    var onReviewLater: (() -> Void)?
    let onResult: (_ confirmed: Bool, _ error: String?) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingRejection = false
    @State private var isWorking = false

    var body: some View {
        let isDisputed = attempt.state == .disputed
        SUCard(padding: SUSpacing.md + 2) {
            VStack(alignment: .leading, spacing: SUSpacing.md) {
                SUStatusChip(title: isDisputed ? String(localized: "Disputed") : String(localized: "Waiting for you"),
                             systemImage: isDisputed ? "exclamationmark.bubble" : "hourglass", tone: .warning)
                HStack(alignment: .top, spacing: SUSpacing.sm) {
                    if let payer = members[attempt.payerID] {
                        SUAvatar(member: payer, size: .medium)
                    }
                    Text(PaymentStatusLanguage.recipientQuestion(for: attempt, members: members))
                        .font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("confirm.question")
                }
                Text(String(localized: "Square Up can't see \(attempt.provider.displayName). Check that the money arrived before confirming."))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Confirm received")) { Task { await act(.confirm, confirmed: true) } }
                    .buttonStyle(.suPrimary)
                    .disabled(isWorking)
                    .accessibilityIdentifier("confirm.received")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SUSpacing.sm) { secondaryActions }
                    VStack(spacing: SUSpacing.sm) { secondaryActions }
                }
                if let onReviewLater {
                    Button(String(localized: "Review later"), action: onReviewLater)
                        .buttonStyle(.suText)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("confirm.later")
                }
            }
        }
        .confirmationDialog(String(localized: "Mark as not received?"), isPresented: $isConfirmingRejection, titleVisibility: .visible) {
            Button(String(localized: "Not received"), role: .destructive) {
                Task { await act(.reject(reason: nil), confirmed: false) }
            }
        } message: {
            Text("\(MoneyFormatting.string(attempt.amount)) will be owed to you again, and \(members[attempt.payerID]?.firstName ?? "") will see that you didn't receive it.")
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button(String(localized: "Not received"), role: .destructive) { isConfirmingRejection = true }
            .buttonStyle(.suDestructive)
            .disabled(isWorking)
            .accessibilityIdentifier("confirm.notReceived")
        if attempt.state == .reportedSent {
            Button(String(localized: "Dispute")) {
                Task { await act(.dispute(reason: nil), confirmed: false) }
            }
            .buttonStyle(.suSecondary)
            .disabled(isWorking)
            .accessibilityLabel(String(localized: "Something's not right — dispute"))
            .accessibilityIdentifier("confirm.dispute")
        }
    }

    private func act(_ action: PaymentAttemptAction, confirmed: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.ledger.advance(attempt.id, action, as: actor)
            onResult(confirmed, nil)
        } catch {
            onResult(false, LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: members))
        }
    }
}

/// PROTOTYPE: the recipient's screen, played locally with a labelled sample identity.
private struct SampleRecipientSheet: View {
    let summary: PaymentAttemptSummary
    let finished: (_ confirmed: Bool) -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    if let recipient = summary.recipient {
                        Label(String(localized: "Acting as \(recipient.displayName) · local prototype"), systemImage: "person.crop.circle.badge.questionmark")
                            .font(SUFont.chip).foregroundStyle(SUColor.violet)
                    }
                    if let error {
                        SUConfirmationBanner(title: String(localized: "Not changed"), message: error,
                                             systemImage: "exclamationmark.triangle.fill", tone: .negative)
                    }
                    RecipientConfirmationCard(
                        attempt: summary.attempt, members: summary.members, actor: summary.attempt.recipientID,
                        onReviewLater: { finished(false) }
                    ) { confirmed, message in
                        error = message
                        if message == nil { finished(confirmed) }
                    }
                }
                .padding(SUSpacing.screenMargin)
            }
            .suScreenBackground()
            .navigationTitle(String(localized: "Recipient's view"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
