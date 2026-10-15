import MessageUI
import SwiftUI

/// One payment handoff (milestone 2 §12).
///
/// 1. A pending `PaymentAttempt` already exists before anything leaves Square Up.
/// 2. Details are prepared (copied locally, expiring) and only allowlisted links are opened.
/// 3. On return, the payer chooses explicitly: Yes, I sent it / Not yet / Cancel attempt.
/// Opening another app is recorded only as "handoff opened" — never as paid.
struct HandoffSheet: View {
    let active: ActiveHandoff
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    enum Stage: Equatable {
        case ready
        case awaitingReturn
        case askResult
        case reported
        case failed(String)
    }

    @State private var stage: Stage = .ready
    @State private var attempt: PaymentAttempt?
    @State private var isComposing = false
    @State private var leftApp = false
    @State private var copiedLabel: String?
    @State private var reference = ""
    @State private var actionError: String?
    @State private var reportCount = 0

    private var current: PaymentAttempt { attempt ?? active.attempt }

    private var plan: HandoffPlan {
        HandoffPlanner.plan(
            destination: active.destination, provider: current.provider, amount: current.amount, memo: current.memo,
            reference: current.reference, recipientName: active.recipient.firstName, groupName: active.groupName, locale: locale
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    summaryCard
                    switch stage {
                    case .ready, .failed:
                        if case .failed(let message) = stage {
                            SUConfirmationBanner(title: String(localized: "Couldn't open \(current.provider.displayName)"), message: message,
                                                 systemImage: "exclamationmark.triangle.fill", tone: .warning)
                        }
                        instructions
                    case .awaitingReturn:
                        awaitingReturn
                    case .askResult:
                        resultPrompt
                    case .reported:
                        reported
                    }
                    if let actionError {
                        SUConfirmationBanner(title: String(localized: "Not changed"), message: actionError,
                                             systemImage: "exclamationmark.triangle.fill", tone: .negative)
                    }
                }
                .padding(SUSpacing.screenMargin)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .navigationTitle(current.provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .reported ? String(localized: "Done") : String(localized: "Close")) { dismiss() }
                        .accessibilityIdentifier("handoff.close")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomAction }
        }
        .interactiveDismissDisabled(stage == .askResult)
        .sheet(isPresented: $isComposing) {
            if case .composeMessage(let recipient, let body) = plan.action {
                MessageComposeView(recipient: recipient, body: body) { result in
                    isComposing = false
                    Task { await messagesFinished(result) }
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, stage == .awaitingReturn { leftApp = true }
            if phase == .active, leftApp, stage == .awaitingReturn {
                leftApp = false
                stage = .askResult
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: reportCount)
        .sensoryFeedback(.selection, trigger: copiedLabel)
    }

    // MARK: Sections

    private var summaryCard: some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                HStack(spacing: SUSpacing.sm) {
                    SUAvatar(member: active.recipient, size: .medium)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(localized: "Paying \(active.recipient.displayName)")).font(SUFont.cardTitle)
                        if let handle = active.recipient.handle {
                            Text("@\(handle)").font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        }
                    }
                }
                SUAmountView(money: current.amount, style: .large)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SUSpacing.xs) { summaryChips }
                    VStack(alignment: .leading, spacing: SUSpacing.xs) { summaryChips }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var summaryChips: some View {
        SUCapsuleLabel(title: plan.capability.label, systemImage: plan.capability.symbolName, tone: .neutral)
        PaymentStateChip(state: current.state)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            if let warning = plan.warning {
                SUConfirmationBanner(title: warning, systemImage: "exclamationmark.shield", tone: .warning)
            }
            if case .composeMessage = plan.action, !environment.handoff.canComposeMessages {
                SUConfirmationBanner(
                    title: String(localized: "Messages isn't available on this device"),
                    message: String(localized: "Copy the amount, send it with Apple Cash from another device, then come back and report it."),
                    systemImage: "message.badge", tone: .informational
                )
                .accessibilityIdentifier("handoff.messagesUnavailable")
            }
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUSectionHeader(title: String(localized: "How it works"))
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: SUSpacing.sm) {
                        Text("\(index + 1)").font(SUFont.chip.monospacedDigit()).foregroundStyle(SUColor.onAccent)
                            .frame(width: 24, height: 24).background(SUColor.accent, in: Circle()).accessibilityHidden(true)
                        Text(step).font(SUFont.supporting).foregroundStyle(SUColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !plan.copyItems.isEmpty {
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    SUSectionHeader(title: String(localized: "Details"))
                    ForEach(plan.copyItems, id: \.self) { item in copyRow(item) }
                }
            }
            ForEach(plan.secondaryLinks, id: \.self) { link in
                Button(link.title, systemImage: "arrow.up.forward.app") {
                    Task { await openLink(link.url) }
                }
                .buttonStyle(.suSecondary)
            }
            if current.state.isDraft {
                Button(String(localized: "I already sent it")) { stage = .askResult }
                    .buttonStyle(.suSecondary)
                    .accessibilityIdentifier("handoff.alreadySent")
            }
        }
    }

    private func copyRow(_ item: HandoffCopyItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.label).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                Text(item.value).font(SUFont.body.monospacedDigit()).foregroundStyle(SUColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(copiedLabel == item.label ? String(localized: "Copied") : String(localized: "Copy")) {
                environment.handoff.copy(item.value)
                copiedLabel = item.label
            }
            .buttonStyle(.borderless)
            .frame(minHeight: SUMetrics.minimumTouchTarget)
            .accessibilityLabel(copiedLabel == item.label ? String(localized: "\(item.label) copied") : String(localized: "Copy \(item.label)"))
        }
        .padding(SUSpacing.sm)
        .suSurface(SUShape.compact)
    }

    private var awaitingReturn: some View {
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            SUConfirmationBanner(
                title: String(localized: "Finish in \(current.provider.displayName)"),
                message: String(localized: "When you come back, Square Up will ask whether you sent it. Opening an app doesn't count as paying."),
                systemImage: "arrow.up.forward.app", tone: .informational
            )
            Button(String(localized: "I'm back")) { stage = .askResult }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("handoff.back")
        }
    }

    /// The return prompt. Three distinct, equally weighted choices; none is preselected.
    private var resultPrompt: some View {
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            Text(PaymentStatusLanguage.returnQuestion(for: current, members: [active.recipient.id: active.recipient]))
                .font(SUFont.sectionTitle)
                .foregroundStyle(SUColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("handoff.question")
            TextField(String(localized: "Confirmation number (optional)"), text: $reference)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(SUSpacing.sm)
                .suSurface(SUShape.compact)
            Text(String(localized: "Reporting doesn't settle anything yet. \(active.recipient.firstName) confirms when the money arrives."))
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            Button(String(localized: "Yes, I sent it")) { Task { await report() } }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("handoff.yesSent")
            Button(String(localized: "Not yet")) { stage = .ready }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("handoff.notYet")
            Button(String(localized: "Cancel attempt"), role: .destructive) { Task { await cancel() } }
                .buttonStyle(.suDestructive)
                .accessibilityIdentifier("handoff.cancelAttempt")
        }
    }

    private var reported: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            Label(String(localized: "Reported as sent"), systemImage: "hourglass")
                .font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
            Text(String(localized: "Waiting for \(active.recipient.firstName) to confirm they received \(MoneyFormatting.string(current.amount)). It won't be suggested again in the meantime."))
                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("handoff.reported")
    }

    @ViewBuilder
    private var bottomAction: some View {
        if stage == .ready || isFailed {
            Button(action: { Task { await primaryAction() } }) {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xs)
            .accessibilityIdentifier("handoff.primary")
        }
    }

    private var isFailed: Bool { if case .failed = stage { true } else { false } }

    private var primaryTitle: String {
        if case .composeMessage = plan.action, !environment.handoff.canComposeMessages {
            return String(localized: "Copy amount")
        }
        return plan.primaryTitle
    }

    // MARK: Actions

    private func primaryAction() async {
        actionError = nil
        switch plan.action {
        case .composeMessage:
            environment.handoff.copy(plan.copyItems.first?.value ?? "")
            copiedLabel = plan.copyItems.first?.label
            if environment.handoff.isSimulating {
                await messagesFinished(.sent)
            } else if environment.handoff.canComposeMessages {
                isComposing = true
            }
        case .openURL(let url):
            await openLink(url)
        case .copyDetails:
            environment.handoff.copy(plan.copyItems.map(\.value).joined(separator: "\n"))
            copiedLabel = String(localized: "All details")
            stage = .awaitingReturn
            if environment.handoff.isSimulating { stage = .askResult }
        case .recordManually:
            stage = .askResult
        }
    }

    private func openLink(_ url: URL) async {
        let opened = await environment.handoff.open(url, for: current.provider)
        guard opened else {
            stage = .failed(String(localized: "The app may not be installed, or the link couldn't be opened. Copy the details below and pay another way."))
            return
        }
        await advance(.openHandoff)
        stage = environment.handoff.isSimulating ? .askResult : .awaitingReturn
    }

    private func messagesFinished(_ result: MessageComposeResult) async {
        switch result {
        case .sent:
            await advance(.openHandoff)
            stage = .askResult
        case .cancelled:
            actionError = String(localized: "The message wasn't sent. Nothing was recorded.")
        case .failed:
            stage = .failed(String(localized: "Messages couldn't send. Copy the amount and try Apple Cash in Messages directly."))
        @unknown default:
            stage = .ready
        }
    }

    private func report() async {
        if await advance(.reportSent(externalReference: reference)) {
            reportCount += 1
            stage = .reported
        }
    }

    private func cancel() async {
        if await advance(.cancel(.payerCancelled)) { dismiss() }
    }

    @discardableResult
    private func advance(_ action: PaymentAttemptAction) async -> Bool {
        do {
            let result = try await environment.ledger.advance(current.id, action)
            if let updated = result.attempt { attempt = updated }
            actionError = nil
            return true
        } catch {
            actionError = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
            return false
        }
    }
}
