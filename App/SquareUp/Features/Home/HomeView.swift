import SwiftUI
import TipKit

/// Home: who you are and where everything stands — the wallet of groups that need you with your
/// overall position in its pocket, the three primary actions, what's open on each side, then
/// receipts and payments in progress and recent activity.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HomeScreen(environment: environment)
    }
}

private struct HomeScreen: View {
    let environment: AppEnvironment
    @State private var model: HomeModel
    @State private var contentWidth: CGFloat = 390
    @State private var isShowingAllSquare = false
    @State private var success: PaymentSuccess?
    @State private var isJoiningReceipt = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let addExpenseTip = AddExpenseTip()

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: HomeModel(ledger: environment.ledger, now: { environment.now },
                                               sharedSnapshots: { [weak sharedGroups = environment.sharedGroups] in
                                                   await sharedGroups?.workspaces() ?? []
                                               }))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.bottom, SUSpacing.xxl)
                .frame(maxWidth: isWide ? 1100 : SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable {
            await environment.sharedGroups.refreshAll()
            await model.load()
        }
        .suScreenBackground()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task(id: environment.ledger.revision) { await model.load() }
        .task(id: environment.sharedGroups.version) { await model.load() }
        .suAnimation(.reveal, value: model.phase)
        .fullScreenCover(item: $success) { success in
            SettlementSuccessView(success: success)
        }
        .sheet(isPresented: $isJoiningReceipt) { JoinWithLinkSheet() }
        .alert(String(localized: "You're all square"), isPresented: $isShowingAllSquare) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text("Nobody owes anything in your groups right now.")
        }
    }

    private var isWide: Bool { contentWidth >= SUMetrics.twoColumnThreshold }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: SUSpacing.lg) {
                HomeHeaderPlaceholder()
                SULoadingState(cardCount: 3)
            }
            .padding(.top, SUSpacing.md)
        case .failed:
            SUErrorState(
                title: String(localized: "Couldn't load your balances"),
                message: String(localized: "Nothing was changed. Your expenses are still saved on this iPhone.")
            ) {
                Task { await model.load() }
            }
            .padding(.top, 120)
        case .loaded(let summary):
            if summary.hasGroups {
                loaded(summary)
            } else {
                HomeEmptyState(summary: summary)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ summary: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            HomeTopBar(
                member: summary.currentUser,
                isOffline: environment.connectivity.isOffline,
                hasSharedGroups: !environment.sharedGroups.summaries.isEmpty,
                isDemo: environment.isDemoWorkspace,
                joinReceipt: environment.sharing.isConfigured ? { isJoiningReceipt = true } : nil
            ) {
                router.select(.profile)
            }
            SUHeadline(primary: String(localized: "\(model.greeting()), \(summary.currentUser.firstName)"),
                       secondary: String(localized: "Here's where you stand."))
                .suRise(0)

            banners
            HomeConfirmationsSection(summary: summary, onConfirmed: celebrate)

            if isWide {
                HStack(alignment: .top, spacing: SUSpacing.lg) {
                    VStack(alignment: .leading, spacing: SUSpacing.lg) {
                        HomeWallet(summary: summary, isAnimated: environment.allowsAmbientAnimation) { router.select(.groups) }
                        actions(summary)
                        openBalances(summary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: SUSpacing.lg) {
                        HomeReceiptsSection(summary: summary)
                        HomePaymentsSection(summary: summary)
                        HomeRecentSection(summary: summary)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                HomeWallet(summary: summary, isAnimated: environment.allowsAmbientAnimation) { router.select(.groups) }
                    .suRise(1)
                actions(summary).suRise(2)
                openBalances(summary).suRise(3)
                HomeReceiptsSection(summary: summary).suRise(4)
                HomePaymentsSection(summary: summary).suRise(4)
                TipView(addExpenseTip)
                    .tipBackground(SUColor.surfaceElevated)
                HomeRecentSection(summary: summary).suRise(5)
            }
        }
        .padding(.top, SUSpacing.xs)
    }

    @ViewBuilder
    private var banners: some View {
        if environment.connectivity.isOffline {
            SUConfirmationBanner(
                title: String(localized: "You're offline"),
                message: lastUpdatedText.map { String(localized: "Showing what's saved on this iPhone · \($0)") }
                    ?? String(localized: "Showing what's saved on this iPhone."),
                systemImage: "icloud.slash",
                tone: .warning
            )
        }
        if model.refreshError != nil {
            SUConfirmationBanner(
                title: String(localized: "Couldn't refresh"),
                message: String(localized: "You're seeing the last loaded balances."),
                systemImage: "exclamationmark.arrow.trianglehead.counterclockwise",
                tone: .warning,
                actionTitle: String(localized: "Retry")
            ) {
                Task { await model.load() }
            }
        }
        // Receipts posted to a shared group, waiting for this person's review (or, for the host, to be finished).
        if let first = groupReceiptsNeedingYou.first {
            let count = groupReceiptsNeedingYou.reduce(0) { $0 + ($1.receiptsNeedingYou ?? 0) }
            SUConfirmationBanner(
                title: count == 1 ? String(localized: "Receipt needs your review") : Inflect.string("^[\(count) receipt](inflect: true) need you"),
                message: groupReceiptsNeedingYou.count == 1 ? String(localized: "In \(first.group.name). Claim what you had and check your share.")
                    : String(localized: "In \(groupReceiptsNeedingYou.map(\.group.name).formatted(.list(type: .and)))."),
                systemImage: "doc.text.magnifyingglass",
                tone: .informational,
                actionTitle: String(localized: "Open")
            ) {
                if let id = GroupID(string: first.group.id) { router.showGroup(id) }
            }
            .accessibilityIdentifier("home.groupReceipts")
        }
    }

    private var groupReceiptsNeedingYou: [GroupSummaryDTO] {
        environment.sharedGroups.summaries.filter { ($0.receiptsNeedingYou ?? 0) > 0 }
    }

    /// The three primary actions as matching glass tiles.
    private func actions(_ summary: HomeSummary) -> some View {
        GlassEffectContainer(spacing: SUSpacing.sm) {
            actionLayout {
                SUActionTile(title: String(localized: "Add expense"), systemImage: "plus") {
                    router.presentComposer()
                }
                .accessibilityIdentifier("home.addExpense")
                SUActionTile(title: String(localized: "Scan receipt"), systemImage: "doc.viewfinder") {
                    router.presentReceiptCapture()
                }
                .accessibilityIdentifier("home.scanReceipt")
                SUActionTile(title: String(localized: "Settle up"), systemImage: "checkmark") {
                    if let groupID = HomeSummaryBuilder.settleUpTarget(in: summary) {
                        router.showSettlePlan(groupID)
                    } else {
                        isShowingAllSquare = true
                    }
                }
                .accessibilityIdentifier("home.settleUp")
            }
        }
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SUSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: SUSpacing.sm))
    }

    private func openBalances(_ summary: HomeSummary) -> some View {
        SUOpenBalancesCard(position: summary.position) {
            Button(String(localized: "All groups"), systemImage: "arrow.up.right") { router.select(.groups) }
                .buttonStyle(.suCircle)
                .accessibilityHint(String(localized: "Shows every group and your position in each"))
        }
        .accessibilityIdentifier("home.openBalances")
    }

    /// The strongest success treatment, only after the current user confirmed receipt.
    private func celebrate(_ attempt: PaymentAttempt) {
        Task {
            let snapshot = try? await environment.environment(for: attempt.groupID).ledger.snapshot()
            let groupSettled = snapshot.flatMap { snapshot in
                snapshot.group(attempt.groupID).map {
                    SettlementPlanner.plan(for: $0, expenses: snapshot.expenses(in: $0.id), settlements: snapshot.settlements(in: $0.id),
                                           attempts: snapshot.attempts(in: $0.id)).isSettled
                }
            } ?? false
            environment.haptics.play(.settle)
            success = PaymentSuccess(
                attempt: snapshot?.attempt(attempt.id) ?? attempt,
                payerName: snapshot?.members[attempt.payerID]?.firstName ?? "",
                recipientName: String(localized: "You"),
                groupName: snapshot?.group(attempt.groupID)?.name ?? "",
                isGroupSettled: groupSettled
            )
        }
    }

    private var lastUpdatedText: String? {
        model.lastUpdated.map { String(localized: "Updated \(RelativeTime.string(for: $0, relativeTo: environment.now))") }
    }
}

/// The top of Home: the Square Up mark, sync state in words, and your avatar to open Profile.
private struct HomeTopBar: View {
    let member: Member
    let isOffline: Bool
    /// With shared groups, not everything is on this iPhone only, so the local-storage chip is hidden.
    var hasSharedGroups = false
    /// Demo Mode: the "Demo" chip, so the sample data is never mistaken for real money.
    var isDemo = false
    /// Joining someone's receipt with a code or link (only when this build has a server).
    var joinReceipt: (() -> Void)?
    let openProfile: () -> Void

    var body: some View {
        HStack(spacing: SUSpacing.sm) {
            SUBrandMark(width: 62)
                .accessibilityRemoveTraits(.isHeader)
            Spacer(minLength: SUSpacing.xs)
            status
            if let joinReceipt {
                Button(action: joinReceipt) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SUColor.textPrimary)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.suPressable)
                .accessibilityLabel(String(localized: "Join a receipt"))
                .accessibilityHint(String(localized: "Enter a room code or paste an invitation link"))
                .accessibilityIdentifier("home.joinReceipt")
            }
            Button(action: openProfile) {
                SUAvatar(member: member, size: .medium, isCurrentUser: true)
                    .padding(2)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.suPressable)
            .accessibilityLabel(String(localized: "\(member.displayName), your profile"))
            .accessibilityHint(String(localized: "Opens your profile"))
        }
        .frame(minHeight: SUMetrics.minimumTouchTarget)
    }

    @ViewBuilder
    private var status: some View {
        // A background reload shows nothing here: swapping the chip for a spinner made the bar jump.
        if isOffline {
            SUStatusChip.offline
        } else if isDemo {
            SUStatusChip(title: String(localized: "Demo"), systemImage: "theatermasks", tone: .informational)
                .accessibilityIdentifier("home.demoChip")
        } else if !hasSharedGroups {
            SUStatusChip.savedOnDevice
        }
    }
}

/// The wallet on Home: the groups that need you as cards (most urgent at the back, on top), and
/// your overall position in the pocket. When nothing is open, one quiet card says so.
private struct HomeWallet: View {
    let summary: HomeSummary
    let isAnimated: Bool
    let showAllGroups: () -> Void
    @Environment(\.groupTransitionNamespace) private var namespace

    private static let cardLimit = 3

    private var cards: [GroupAttention] { Array(summary.attention.prefix(Self.cardLimit)) }
    private var finishes: [SUWalletFinish] { SUWalletFinish.stack(cards.map(\.group.id)) }

    var body: some View {
        let labels = PersonIdentity.shortLabels(for: Array(summary.members.values))
        SUWallet(cardCount: max(cards.count, 1), isAnimated: isAnimated) { index in
            if cards.isEmpty {
                SUWalletCard(finish: .calm) {
                    HomeWalletCardFace(symbol: "checkmark.seal", title: String(localized: "Every group is square"),
                                       detail: String(localized: "Nothing needs you right now"), amount: nil)
                }
                .accessibilityElement(children: .combine)
            } else {
                let item = cards[index]
                NavigationLink(value: AppRoute.group(item.group.id)) {
                    SUWalletCard(finish: finishes[index]) {
                        HomeWalletCardFace(symbol: item.group.symbolName, title: item.group.name,
                                           detail: item.shortReasonText(labels: labels), amount: item.signedAmountText)
                    }
                }
                .buttonStyle(.suPressable)
                .modifier(GroupTransitionSource(id: item.group.id, namespace: namespace))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.group.name). \(item.reasonText(labels: labels))")
                .accessibilityValue(item.spokenAmount)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("home.attention.\(item.group.name)")
            }
        } pocket: {
            SUBalanceCard(position: summary.position, groupCount: summary.activeGroupCount, footnote: footnote) {
                Button(String(localized: "All groups"), systemImage: "arrow.up.right", action: showAllGroups)
                    .buttonStyle(.suCircle)
                    .accessibilityHint(String(localized: "Shows every group and your position in each"))
            }
        }
        .accessibilityIdentifier("home.hero")
    }

    private var footnote: String? {
        var notes: [String] = []
        if summary.otherCurrencyGroupCount > 0 {
            notes.append(Inflect.string("Excludes ^[\(summary.otherCurrencyGroupCount) group](inflect: true) in another currency."))
        }
        let hidden = summary.attention.count - cards.count
        if hidden > 0 {
            notes.append(Inflect.string("^[\(hidden) more group](inflect: true) need you — see all groups."))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// The strip of a wallet card that shows above the pocket.
private struct HomeWalletCardFace: View {
    let symbol: String
    let title: String
    let detail: String
    let amount: String?

    var body: some View {
        HStack(alignment: .top, spacing: SUSpacing.sm) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
            }
            Spacer(minLength: SUSpacing.xs)
            if let amount {
                Text(amount)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

private struct HomeHeaderPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            HStack {
                Capsule().fill(SUColor.glassFillElevated).frame(width: 62, height: 26)
                Spacer()
                Circle().fill(SUColor.glassFillElevated).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading) {
                Text("Good evening, Placeholder")
                Text("Here's where you stand.")
            }
            .font(.system(.title, weight: .semibold))
        }
        .suSkeleton(true)
    }
}

/// A brand-new person: the same composition with an empty wallet — a dashed slot where the
/// first group's card will go — and the way to fill it.
private struct HomeEmptyState: View {
    let summary: HomeSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            SUHeadline(primary: String(localized: "Welcome, \(summary.currentUser.firstName)"),
                       secondary: String(localized: "Let's get everyone square."))
                .padding(.top, SUSpacing.md)
            SUWallet(cardCount: 1, isAnimated: environment.allowsAmbientAnimation) { _ in
                SUWalletPlaceholderCard {
                    HStack(spacing: SUSpacing.sm) {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(String(localized: "Your first group goes here"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(SUColor.textSecondary)
                }
                .accessibilityHidden(true)
            } pocket: {
                pocket
            }
        }
    }

    private var pocket: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUTagPill(title: String(localized: "No groups yet"), systemImage: "person.3.sequence.fill")
            Text(environment.requiresAccount
                ? String(localized: "Create a group for an apartment, a trip, or a dinner crew — or open an invitation a friend sent you.")
                : String(localized: "Groups hold the people you share costs with — an apartment, a trip, or a dinner crew."))
                .font(SUFont.body)
                .foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: SUSpacing.sm) {
                if environment.requiresAccount {
                    // A real account starts empty: no sample groups replace the person's own ledger.
                    Button(String(localized: "Create a group")) { router.groupEditor = .create }
                        .buttonStyle(.suPrimary)
                } else {
                    Button(String(localized: "Explore sample groups")) {
                        Task { try? await environment.resetSampleData() }
                    }
                    .buttonStyle(.suPrimary)
                    Button(String(localized: "Create a group")) { router.groupEditor = .create }
                        .buttonStyle(.suSecondary)
                }
            }
            .padding(.top, SUSpacing.xs)
        }
        .padding(SUSpacing.lg)
    }
}

extension GroupAttention {
    /// "You owe Riley and Lena" / "Maya and 2 more owe you", with short, unambiguous names.
    func reasonText(labels: [MemberID: String]) -> String {
        func names(_ ids: [MemberID]) -> String {
            let shown = ids.prefix(2).compactMap { labels[$0] }
            let others = ids.count - shown.count
            if others > 0 {
                return (shown + [String(localized: "\(others) more")]).formatted(.list(type: .and))
            }
            return shown.formatted(.list(type: .and))
        }
        switch reason {
        case .youOwe(_, let counterparties): return String(localized: "You owe \(names(counterparties))")
        case .owedToYou(_, let counterparties): return String(localized: "\(names(counterparties)) owe you")
        }
    }

    /// The same, compact enough for a card's strip: one or two names, or a count of people.
    func shortReasonText(labels: [MemberID: String]) -> String {
        switch reason {
        case .youOwe(_, let ids):
            if ids.count > 2 { return Inflect.string("You owe ^[\(ids.count) person](inflect: true)") }
            return String(localized: "You owe \(ids.compactMap { labels[$0] }.formatted(.list(type: .and)))")
        case .owedToYou(_, let ids):
            if ids.count > 2 { return Inflect.string("^[\(ids.count) person](inflect: true) owe you") }
            return ids.count == 1
                ? String(localized: "\(labels[ids[0]] ?? "") owes you")
                : String(localized: "\(ids.compactMap { labels[$0] }.formatted(.list(type: .and))) owe you")
        }
    }

    /// The amount with its direction as a sign: "+$377.00" owed to you, "−$29.69" you owe.
    var signedAmountText: String {
        switch reason {
        case .owedToYou(let money, _): "+" + MoneyFormatting.string(money)
        case .youOwe(let money, _): "\u{2212}" + MoneyFormatting.string(money)
        }
    }

    var spokenAmount: String {
        switch reason {
        case .owedToYou(let money, _): String(localized: "you're owed \(MoneyFormatting.spokenString(money))")
        case .youOwe(let money, _): String(localized: "you owe \(MoneyFormatting.spokenString(money))")
        }
    }
}

#Preview("Home · owed") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.standard))
        .environment(AppRouter())
}

#Preview("Home · owes") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.owes))
        .environment(AppRouter())
}

#Preview("Home · large type") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.longNames))
        .environment(AppRouter())
        .dynamicTypeSize(.accessibility3)
}

#Preview("Home · new user") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.newUser))
        .environment(AppRouter())
}

#Preview("Home · loading") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.loading))
        .environment(AppRouter())
}

#Preview("Home · error") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.failure))
        .environment(AppRouter())
}

#Preview("Home · offline") {
    NavigationStack { HomeView() }
        .environment(AppEnvironment.preview(.offline))
        .environment(AppRouter())
}
