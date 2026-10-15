import SwiftUI

/// Everything the paying screen needs, derived from one snapshot.
nonisolated struct PayingSummary: Equatable, Sendable {
    let group: ExpenseGroup
    let payer: Member
    let recipient: Member
    let members: [MemberID: Member]
    /// What the payer currently owes the recipient in the actionable plan. Nil: nothing to pay.
    let amount: Money?
    /// The recipient's enabled methods, preferred first.
    let destinations: [PaymentDestination]
    /// An unfinished draft for this obligation (resume or cancel).
    let draft: PaymentAttempt?
    /// Reported or disputed payments to this recipient, still awaiting confirmation.
    let pending: [PaymentAttempt]

    static func make(groupID: GroupID, recipientID: MemberID, from snapshot: LedgerSnapshot) throws -> PayingSummary {
        guard let group = snapshot.group(groupID) else { throw LedgerError.groupNotFound }
        guard let payer = snapshot.currentUser, let recipient = snapshot.members[recipientID] else {
            throw LedgerError.rule(.memberNotFound)
        }
        let key = PaymentAttempt.obligationKey(groupID: groupID, payerID: payer.id, recipientID: recipientID)
        let attempts = snapshot.attempts(in: groupID).filter { $0.obligationKey == key }
        return PayingSummary(
            group: group, payer: payer, recipient: recipient, members: snapshot.members,
            amount: LedgerEngine.availableObligation(groupID: groupID, payerID: payer.id, recipientID: recipientID, in: snapshot),
            destinations: snapshot.destinations(of: recipientID).filter(\.isEnabled),
            draft: attempts.filter(\.state.isDraft).max { $0.createdAt < $1.createdAt },
            pending: attempts.filter(\.state.reservesObligation)
        )
    }
}

/// "Pay Maya $27.83" — choose one of the recipient's methods (milestone 2 §11).
struct PayingView: View {
    let groupID: GroupID
    let recipientID: MemberID
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        PayingScreen(groupID: groupID, recipientID: recipientID, environment: environment)
    }
}

private struct PayingScreen: View {
    let environment: AppEnvironment
    @State private var model: SnapshotModel<PayingSummary>
    @State private var handoff: ActiveHandoff?
    @State private var errorMessage: String?
    @State private var isStarting = false
    @Environment(AppRouter.self) private var router

    private let recipientIDForReveal: MemberID?

    init(groupID: GroupID, recipientID: MemberID, environment: AppEnvironment) {
        self.environment = environment
        recipientIDForReveal = recipientID
        _model = State(initialValue: SnapshotModel(ledger: environment.ledger) {
            try PayingSummary.make(groupID: groupID, recipientID: recipientID, from: $0)
        })
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "Pay"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: environment.ledger.revision) { await model.load() }
            // Milestone 7: in a shared group, the recipient's payment details come from the server,
            // only while this person owes them (§10.1).
            .task {
                if let shared = environment.sharedGroup, let recipient = model.value?.recipient.id ?? recipientIDForReveal {
                    try? await shared.revealDestinations(of: recipient)
                }
            }
            .sharedGroupSync(environment.sharedGroup)
            .sheet(item: $handoff) { active in
                HandoffSheet(active: active)
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

    private func loaded(_ summary: PayingSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                header(summary)
                if environment.connectivity.isOffline {
                    SUConfirmationBanner(
                        title: String(localized: "You're offline"),
                        message: String(localized: "You can still record a payment here. Some payment apps need a connection."),
                        systemImage: "icloud.slash", tone: .warning
                    )
                }
                if let errorMessage {
                    SUConfirmationBanner(title: String(localized: "Not started"), message: errorMessage,
                                         systemImage: "exclamationmark.triangle.fill", tone: .negative)
                }
                if let draft = summary.draft {
                    unfinished(draft, summary)
                }
                if !summary.pending.isEmpty {
                    pendingNotice(summary)
                }
                if let amount = summary.amount {
                    methods(summary, amount: amount)
                } else {
                    SUEmptyState(
                        systemImage: "checkmark.seal",
                        title: String(localized: "Nothing to pay \(summary.recipient.firstName) right now"),
                        message: summary.pending.isEmpty
                            ? String(localized: "Balances may have changed since you opened this.")
                            : String(localized: "Your reported payment covers what you owed. \(summary.recipient.firstName) just needs to confirm it.")
                    )
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.bottom, SUSpacing.xxl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
    }

    /// Who you're paying on a cover, and what you pay in a frosted pocket rising out of it.
    private func header(_ summary: PayingSummary) -> some View {
        SUCoverPanel(palette: .attention, coverHeight: 0, coverPadding: SUSpacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                // Full identity, so the payer can verify the person before leaving Square Up.
                HStack(alignment: .top, spacing: SUSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.recipient.displayName)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if let handle = summary.recipient.handle {
                            Text("@\(handle)").font(SUFont.supporting).foregroundStyle(.white.opacity(0.66))
                        }
                        Text(summary.group.name).font(SUFont.supporting).foregroundStyle(.white.opacity(0.66))
                    }
                    Spacer(minLength: SUSpacing.xs)
                    SUAvatar(member: summary.recipient, size: .large)
                        .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5) }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(SUSpacing.md)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Paying \(summary.recipient.displayName)"))
                if let amount = summary.amount {
                    Spacer(minLength: 64)
                    SUTabbedPanel(material: .frosted, cornerRadius: SURadius.panel - 6 - SUSpacing.xs) {
                        Label(String(localized: "You pay \(summary.recipient.firstName)"), systemImage: "arrow.up.right")
                            .font(SUFont.chip)
                            .foregroundStyle(.white)
                    } content: {
                        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                            SUAmountView(money: amount, style: .hero, emphasizesWholeUnits: true)
                            Text(String(localized: "Square Up never moves money. You pay in the app you choose."))
                                .font(SUFont.metadata)
                                .foregroundStyle(SUColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, SUSpacing.lg)
                        .padding(.top, SUSpacing.xs)
                        .padding(.bottom, SUSpacing.lg)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Pay \(summary.recipient.firstName) \(MoneyFormatting.string(amount))"))
                    .accessibilityIdentifier("pay.headline")
                }
            }
        }
    }

    @ViewBuilder
    private func methods(_ summary: PayingSummary, amount: Money) -> some View {
        if summary.destinations.isEmpty {
            noMethods(summary)
        } else {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(
                    title: String(localized: "\(summary.recipient.firstName) accepts"),
                    subtitle: String(localized: "Choose one. You'll come back here to say whether you sent it.")
                )
                ForEach(summary.destinations) { destination in
                    PaymentMethodRow(destination: destination, isDisabled: isStarting) {
                        Task { await start(summary, amount: amount, destination: destination, provider: destination.provider) }
                    }
                }
                Button(String(localized: "I paid another way")) {
                    Task { await start(summary, amount: amount, destination: nil, provider: .other) }
                }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("pay.otherWay")
            }
        }
    }

    private func noMethods(_ summary: PayingSummary) -> some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                Label(String(localized: "\(summary.recipient.firstName) hasn't added payment methods yet"), systemImage: "questionmark.circle")
                    .font(SUFont.cardTitle)
                Text(String(localized: "You can still settle up — ask how they'd like to be paid, or pay another way and record it."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                ShareLink(item: String(localized: "Hi \(summary.recipient.firstName)! How would you like me to pay you for \(summary.group.name)? (Square Up)")) {
                    Label(String(localized: "Ask \(summary.recipient.firstName) how they want to be paid"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.suSecondary)
                .accessibilityIdentifier("pay.ask")
                if let amount = summary.amount {
                    Button(String(localized: "Record a manual payment")) {
                        Task { await start(summary, amount: amount, destination: nil, provider: .other) }
                    }
                    .buttonStyle(.suPrimary)
                    .accessibilityIdentifier("pay.manual")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pay.noMethods")
    }

    private func unfinished(_ draft: PaymentAttempt, _ summary: PayingSummary) -> some View {
        SUConfirmationBanner(
            title: String(localized: "Unfinished \(draft.provider.displayName) payment"),
            message: String(localized: "You started paying \(MoneyFormatting.string(draft.amount)) but haven't reported it. Nothing has been recorded."),
            systemImage: "arrow.uturn.forward.circle",
            tone: .informational,
            actionTitle: String(localized: "Resume")
        ) {
            handoff = ActiveHandoff(attempt: draft, destination: draft.destinationID.flatMap { id in summary.destinations.first { $0.id == id } },
                                    recipient: summary.recipient, groupName: summary.group.name)
        }
    }

    private func pendingNotice(_ summary: PayingSummary) -> some View {
        VStack(spacing: SUSpacing.xs) {
            ForEach(summary.pending) { attempt in
                Button {
                    router.push(.paymentAttempt(attempt.id))
                } label: {
                    PendingAttemptRow(attempt: attempt, members: summary.members, currentUserID: summary.payer.id)
                        .padding(.horizontal, SUSpacing.sm)
                        .suSurface(SUShape.compact)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func start(_ summary: PayingSummary, amount: Money, destination: PaymentDestination?, provider: PaymentProviderKind) async {
        isStarting = true
        defer { isStarting = false }
        do {
            let attempt = try await environment.ledger.startPayment(PaymentRequest(
                groupID: summary.group.id, payerID: summary.payer.id, recipientID: summary.recipient.id,
                amount: amount, provider: provider, destinationID: destination?.id
            ))
            errorMessage = nil
            handoff = ActiveHandoff(attempt: attempt, destination: destination, recipient: summary.recipient, groupName: summary.group.name)
        } catch {
            errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: summary.members)
        }
    }
}

/// A payment-method row: text name, destination, capability, and action — never logo-only.
struct PaymentMethodRow: View {
    let destination: PaymentDestination
    var isDisabled = false
    let choose: () -> Void

    var body: some View {
        let usable = HandoffPlanner.isUsable(destination)
        let plan = HandoffPlanner.plan(destination: destination, provider: destination.provider, amount: Money(1),
                                       memo: "", reference: "", recipientName: "", groupName: "")
        Button(action: choose) {
            HStack(alignment: .center, spacing: SUSpacing.sm) {
                ProviderMark(provider: destination.provider)
                VStack(alignment: .leading, spacing: 2) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SUSpacing.xs) { nameAndBadge }
                        VStack(alignment: .leading, spacing: SUSpacing.xxs) { nameAndBadge }
                    }
                    Text(DestinationPresentation.revealed(destination.value, provider: destination.provider))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if usable {
                        Label(plan.capability.label, systemImage: plan.capability.symbolName)
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    } else {
                        Label(String(localized: "Details incomplete · copy amount only"), systemImage: "exclamationmark.triangle")
                            .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SUSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .suSurface(SUShape.card)
            .contentShape(SUShape.card)
        }
        .buttonStyle(.suPressable)
        .disabled(isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(usable: usable, capability: plan.capability))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("pay.method.\(destination.provider.rawValue)")
    }

    @ViewBuilder
    private var nameAndBadge: some View {
        Text(destination.label ?? destination.provider.displayName)
            .font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary)
        if destination.isPreferred {
            SUCapsuleLabel(title: String(localized: "Preferred"), systemImage: "star.fill", tone: .accent)
        }
    }

    private func accessibilityText(usable: Bool, capability: HandoffCapability) -> String {
        var parts = [destination.label ?? destination.provider.displayName]
        if destination.isPreferred { parts.append(String(localized: "preferred")) }
        parts.append(DestinationPresentation.revealed(destination.value, provider: destination.provider))
        parts.append(usable ? capability.label : String(localized: "details incomplete"))
        return parts.joined(separator: ", ")
    }
}

/// Neutral provider mark: SF Symbol plus the name elsewhere in the row. No third-party logos
/// are bundled (milestone 2 §17: official assets only where their terms are satisfied).
struct ProviderMark: View {
    let provider: PaymentProviderKind

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(SUColor.accent)
            .frame(width: 44, height: 44)
            .background(SUColor.accent.opacity(0.12), in: SUShape.control)
            .accessibilityHidden(true)
    }
}

extension PaymentProviderKind {
    var symbolName: String {
        switch self {
        case .appleCash: "message.fill"
        case .paypal: "p.circle.fill"
        case .cashApp: "dollarsign.square.fill"
        case .zelle: "building.columns.fill"
        case .venmo: "v.circle.fill"
        case .cash: "banknote.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}

/// The attempt currently being handed off.
struct ActiveHandoff: Identifiable {
    let attempt: PaymentAttempt
    let destination: PaymentDestination?
    let recipient: Member
    let groupName: String
    var id: PaymentAttemptID { attempt.id }
}

#Preview("Pay Maya") {
    NavigationStack { PayingView(groupID: SampleLedger.GroupKey.apartment.id, recipientID: SampleLedger.Person.maya.id) }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}
