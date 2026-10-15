import SwiftUI
import TipKit

/// The five most recent records that involve the person.
struct HomeRecentSection: View {
    let summary: HomeSummary
    @Environment(AppRouter.self) private var router

    var body: some View {
        SUPanelSection(
            title: String(localized: "Recent activity"),
            actionTitle: summary.recent.isEmpty ? nil : String(localized: "See all")
        ) {
            router.select(.activity)
        } content: {
            if summary.recent.isEmpty {
                Text(String(localized: "Expenses and payments you're part of will appear here."))
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.recent) { entry in
                        SUTransactionRow(entry: entry, members: summary.members)
                        if entry.id != summary.recent.last?.id {
                            Divider().overlay(SUColor.hairline).padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }
}

/// Payments someone reported sending to this person, waiting for them to confirm (milestone 2 §13).
/// First on Home, under the greeting: money that may have arrived never waits below the fold.
struct HomeConfirmationsSection: View {
    let summary: HomeSummary
    let onConfirmed: (PaymentAttempt) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var errorMessage: String?

    var body: some View {
        if !summary.paymentsToConfirm.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: summary.paymentsToConfirm.count == 1 ? String(localized: "Confirm a payment")
                    : String(localized: "Confirm \(summary.paymentsToConfirm.count) payments"),
                    subtitle: String(localized: "Only you can say whether the money arrived."))
                if let errorMessage {
                    SUConfirmationBanner(title: String(localized: "Not changed"), message: errorMessage,
                                         systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                ForEach(summary.paymentsToConfirm) { attempt in
                    // Milestone 7: each payment runs on its own group's ledger (a shared group's server, or
                    // this iPhone), acting as the recipient's seat in that group.
                    RecipientConfirmationCard(
                        attempt: attempt, members: summary.members, actor: attempt.recipientID,
                        onReviewLater: { router.push(.paymentAttempt(attempt.id)) }
                    ) { confirmed, error in
                        errorMessage = error
                        if confirmed { onConfirmed(attempt) }
                    }
                    .environment(environment.environment(for: attempt.groupID))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.confirmations")
        }
    }
}

/// Payments of this person's that are still in motion: a handoff never reported, and ones waiting
/// for someone else's confirmation (milestone 2 §12–13).
struct HomePaymentsSection: View {
    let summary: HomeSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var errorMessage: String?

    var body: some View {
        if !summary.unfinishedPayments.isEmpty || !summary.awaitingOthers.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: String(localized: "Payments"))
                if let errorMessage {
                    SUConfirmationBanner(title: String(localized: "Not changed"), message: errorMessage,
                                         systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                ForEach(summary.unfinishedPayments) { attempt in
                    unfinished(attempt)
                }
                if !summary.awaitingOthers.isEmpty {
                    SUCard(padding: SUSpacing.sm + 2) {
                        VStack(spacing: 0) {
                            ForEach(summary.awaitingOthers) { attempt in
                                Button { router.push(.paymentAttempt(attempt.id)) } label: {
                                    PendingAttemptRow(attempt: attempt, members: summary.members, currentUserID: summary.currentUser.id)
                                }
                                .buttonStyle(.plain)
                                if attempt.id != summary.awaitingOthers.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The persistent return prompt for a handoff that was never reported (e.g. the app was
    /// closed while the payment app was open). No option is preselected.
    private func unfinished(_ attempt: PaymentAttempt) -> some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Text(PaymentStatusLanguage.returnQuestion(for: attempt, members: summary.members))
                    .font(SUFont.cardTitle)
                    .accessibilityIdentifier("home.returnQuestion")
                Text(String(localized: "You opened \(attempt.provider.displayName) for \(summary.groupNames[attempt.groupID] ?? ""). Nothing has been recorded yet."))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SUSpacing.xs) { unfinishedButtons(attempt) }
                    VStack(spacing: SUSpacing.xs) { unfinishedButtons(attempt) }
                }
            }
        }
    }

    @ViewBuilder
    private func unfinishedButtons(_ attempt: PaymentAttempt) -> some View {
        Button(String(localized: "Yes, I sent it")) { Task { await advance(attempt, .reportSent(externalReference: nil)) } }
            .buttonStyle(.suSecondary)
        Button(String(localized: "Not yet")) { router.push(.pay(groupID: attempt.groupID, recipientID: attempt.recipientID)) }
            .buttonStyle(.suSecondary)
        Button(String(localized: "Cancel attempt"), role: .destructive) { Task { await advance(attempt, .cancel(.payerCancelled)) } }
            .buttonStyle(.suDestructive)
    }

    private func advance(_ attempt: PaymentAttempt, _ action: PaymentAttemptAction) async {
        do {
            try await environment.environment(for: attempt.groupID).ledger.advance(attempt.id, action)
            errorMessage = nil
        } catch {
            errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: summary.members)
        }
    }
}

/// Milestone 3: drafts and Live Receipt Rooms waiting to be finished (they survive relaunch).
struct HomeReceiptsSection: View {
    let summary: HomeSummary
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment

    private var receipts: [ReceiptRoom] { summary.unfinishedReceipts.filter { environment.isInProgress($0.id) } }

    var body: some View {
        if !receipts.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: String(localized: "Receipts in progress"))
                ForEach(receipts) { room in
                    UnfinishedReceiptRow(room: room, groupName: room.groupID.flatMap { summary.groupNames[$0] },
                                         status: environment.progressText(for: room.id)) {
                        router.open(room.id, in: environment)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.receipts")
        }
    }
}
