import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// After review: where the receipt goes. Two clearly different ways, never a forced group choice.
///
/// - **Add to a group**: choose the group, who was there, and who had what on one screen; it's
///   added right away as one itemized group expense. No room opens for anyone.
/// - **Split with people now**: a temporary room with a QR code, a link, and a short code. Anyone
///   at the table joins without a group; they pay the payer back and the payer confirms.
struct ChoosePathView: View {
    let flow: ReceiptFlowModel
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                SUHeadline(primary: String(localized: "How do you want to split it?"),
                           secondary: String(localized: "You can't change this afterwards."))
                if let room = flow.room { receiptSummary(room) }
                PathCard(
                    title: String(localized: "Add to a group"),
                    message: String(localized: "Pick who was there and who had what. It's added to the group right away as one itemized expense."),
                    systemImage: "person.3.fill", palette: .calm, identifier: "path.group"
                ) { flow.show(.addToGroup) }
                PathCard(
                    title: String(localized: "Split with people now"),
                    message: String(localized: "Show a QR code or a short code at the table. Friends join without a group, claim what they had, and pay you back."),
                    systemImage: "qrcode", palette: .attention, identifier: "path.now"
                ) { flow.show(.splitNow) }
                Button(String(localized: "Back to review")) { flow.show(.review) }
                    .buttonStyle(.suSecondary(fullWidth: true))
                    .accessibilityIdentifier("path.back")
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Split receipt"))
    }

    private func receiptSummary(_ room: ReceiptRoom) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.title).font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary).lineLimit(2)
                Text(Inflect.string("^[\(room.receipt.items.filter { !$0.isNote }.count) item](inflect: true) · \(room.receipt.date.value.formatted(date: .abbreviated, time: .omitted))"))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
            Spacer(minLength: SUSpacing.xs)
            if let total = room.receipt.total.value { SUAmountView(money: total, style: .row) }
        }
        .padding(SUSpacing.md)
        .suSurface(SUShape.card)
        .accessibilityElement(children: .combine)
    }
}

/// One way of splitting, as a large tappable panel.
private struct PathCard: View {
    let title: String
    let message: String
    let systemImage: String
    let palette: SUMeshBackground.Palette
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: SUSpacing.md) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background { SUCoverArt(palette: palette, symbol: nil, isAnimated: false).clipShape(SUShape.compact) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    Text(title).font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
                    Text(message).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SUSpacing.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .suSurface(RoundedRectangle(cornerRadius: SURadius.panel - 6, style: .continuous), elevated: true)
            .contentShape(RoundedRectangle(cornerRadius: SURadius.panel - 6, style: .continuous))
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Add to a group

/// Choose the group, then — on one screen — the people who were there, who paid, and who had each
/// item. It's added to the group right away as one itemized expense (`ReceiptGroupAddition`), for a
/// shared group and a group on this iPhone alike. Live rooms are only for "Split with people now".
struct AddToGroupView: View {
    let flow: ReceiptFlowModel
    @Environment(AppEnvironment.self) private var environment
    @State private var choice: GroupChoice?
    @State private var people: [Member] = []
    @State private var selected: Set<MemberID> = []
    @State private var payer: MemberID?
    @State private var viewer: MemberID?
    @State private var assignments: [ReceiptItemID: [MemberID]] = [:]
    @State private var isWorking = false
    @State private var failure: String?

    struct GroupChoice: Identifiable, Hashable {
        let id: GroupID
        let name: String
        let symbol: String
        let currency: CurrencyCode
        let isShared: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let choice {
                    peopleStep(choice)
                } else {
                    groupStep
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .padding(.bottom, 120)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Add to a group"))
        .safeAreaInset(edge: .bottom) { if choice != nil { postBar } }
    }

    private var currency: CurrencyCode { flow.room?.receipt.currencyCode ?? .usd }

    /// Shared groups everywhere; groups on this iPhone only when the draft lives on this iPhone's ledger.
    private var sharedChoices: [GroupChoice] {
        environment.sharedGroups.summaries.filter { $0.group.archivedAt == nil }.compactMap { summary in
            guard let id = GroupID(string: summary.group.id) else { return nil }
            return GroupChoice(id: id, name: summary.group.name, symbol: summary.group.symbol, currency: CurrencyCode(summary.group.currency),
                               isShared: true)
        }
    }

    private var localChoices: [GroupChoice] {
        guard !environment.isInsideSharedGroup, let snapshot = flow.snapshot else { return [] }
        return snapshot.groupsForCurrentUser.map { GroupChoice(id: $0.id, name: $0.name, symbol: $0.symbolName, currency: $0.currency, isShared: false) }
    }

    @ViewBuilder
    private var groupStep: some View {
        SUHeadline(primary: String(localized: "Which group?"), secondary: String(localized: "Next, choose who was there and who had what."))
        if sharedChoices.isEmpty, localChoices.isEmpty {
            SUEmptyState(systemImage: "person.3", title: String(localized: "No groups yet"),
                         message: String(localized: "Create a group first, or split this receipt with people now."),
                         primaryTitle: String(localized: "Split with people now")) { flow.show(.splitNow) }
        }
        if !sharedChoices.isEmpty {
            SUPanelSection(title: String(localized: "Shared groups")) {
                ForEach(sharedChoices) { groupRow($0) }
            }
        }
        if !localChoices.isEmpty {
            SUPanelSection(title: String(localized: "On this iPhone")) {
                ForEach(localChoices) { groupRow($0) }
            }
        }
        if let failure {
            SUConfirmationBanner(title: String(localized: "Couldn't open that group"), message: failure, systemImage: "exclamationmark.triangle.fill",
                                 tone: .negative)
        }
        Button(String(localized: "Back")) { flow.show(.choosing) }.buttonStyle(.suSecondary(fullWidth: true))
    }

    private func groupRow(_ group: GroupChoice) -> some View {
        let matches = group.currency == currency
        return Button {
            Task { await select(group) }
        } label: {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: group.symbol).font(.title3).foregroundStyle(SUColor.textPrimary)
                    .frame(width: 40, height: 40).background(SUColor.glassFillElevated, in: SUShape.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    if !matches {
                        Text(String(localized: "Uses \(group.currency.rawValue); this receipt is in \(currency.rawValue)"))
                            .font(SUFont.metadata).foregroundStyle(SUColor.warning)
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary).accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.suPressable)
        .disabled(!matches || isWorking)
        .accessibilityIdentifier("addToGroup.group.\(group.name)")
    }

    private func select(_ group: GroupChoice) async {
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot: LedgerSnapshot
            if group.isShared {
                guard let ledger = environment.sharedGroups.ledger(for: group.id) else { throw LedgerError.groupNotFound }
                snapshot = try await ledger.snapshot()
                // You assign everyone's items here, so people who haven't joined yet can be on it too.
                people = snapshot.group(group.id).map { snapshot.activeMembers(of: $0) } ?? []
                viewer = ledger.viewerID
            } else {
                guard let local = flow.snapshot else { throw LedgerError.unavailable }
                snapshot = local
                people = snapshot.group(group.id).map { snapshot.activeMembers(of: $0) } ?? []
                viewer = snapshot.currentUserID
            }
            selected = Set(people.map(\.id))
            payer = viewer
            assignments = [:]
            choice = group
        } catch {
            failure = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
        }
    }

    @ViewBuilder
    private func peopleStep(_ group: GroupChoice) -> some View {
        SUHeadline(primary: String(localized: "Who was there?"), secondary: group.name)
        SUPanelSection(title: String(localized: "People on this receipt"),
                       subtitle: String(localized: "Everyone who shares this receipt.")) {
            VStack(spacing: 0) {
                ForEach(people) { member in
                    let isYou = member.id == viewer
                    SUUserPickerRow(member: member, detail: isYou ? String(localized: "You're adding it") : nil, isCurrentUser: isYou,
                                    isSelected: selected.contains(member.id)) {
                        guard !isYou else { return } // the person adding it is always on their own receipt
                        if selected.contains(member.id) { selected.remove(member.id) } else { selected.insert(member.id) }
                        if let payer, !selected.contains(payer) { self.payer = viewer }
                        // Someone taken off the receipt comes off its items too.
                        assignments = assignments.mapValues { $0.filter(selected.contains) }
                    }
                    .accessibilityIdentifier("addToGroup.person.\(member.firstName)")
                }
            }
        }
        SUPanelSection(title: String(localized: "Who paid?")) {
            Picker(String(localized: "Paid by"), selection: Binding(get: { payer }, set: { payer = $0 })) {
                ForEach(people.filter { selected.contains($0.id) }) { member in
                    Text(member.id == viewer ? String(localized: "\(member.displayName) (you)") : member.displayName).tag(MemberID?.some(member.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("addToGroup.payer")
        }
        if let room = flow.room {
            ItemAssignmentPanel(room: room, people: onReceipt, viewer: viewer, assignments: $assignments,
                                breakdown: ReceiptGroupAddition.breakdown(room, plan: plan(payer: payer ?? viewer)))
        }
        if group.isShared {
            Label(String(localized: "The group sees the items and amounts, not the receipt photo."), systemImage: "lock")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        }
        if let failure {
            SUConfirmationBanner(title: String(localized: "Not added"), message: failure, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                .accessibilityIdentifier("addToGroup.error")
        }
    }

    /// The selected people, in the group's order.
    private var onReceipt: [Member] { people.filter { selected.contains($0.id) } }

    private func plan(payer: MemberID?) -> ReceiptGroupAddition.Plan {
        ReceiptGroupAddition.Plan(participants: onReceipt.map(\.id), payer: payer ?? viewer ?? onReceipt.first?.id ?? MemberID(), items: assignments)
    }

    private var isFullyAssigned: Bool {
        guard let room = flow.room else { return false }
        return ReceiptGroupAddition.assignableItems(of: room).allSatisfy { !(assignments[$0.id] ?? []).isEmpty }
    }

    private var postBar: some View {
        VStack(spacing: SUSpacing.xs) {
            Button {
                Task { await post() }
            } label: {
                HStack {
                    if isWorking { ProgressView() }
                    Text(String(localized: "Add to \(choice?.name ?? "")"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .disabled(isWorking || payer == nil || selected.isEmpty || !isFullyAssigned)
            .accessibilityIdentifier("addToGroup.post")
            Button(String(localized: "Choose another group")) { choice = nil; failure = nil }
                .buttonStyle(.suSecondary(fullWidth: true))
        }
        .padding(SUSpacing.md)
        .background(.bar)
    }

    private func post() async {
        guard let choice, let payer, let room = flow.room else { return }
        failure = nil
        isWorking = true
        defer { isWorking = false }
        let target = environment.environment(for: choice.id).ledger
        do {
            _ = try await ReceiptGroupAddition.add(room, from: flow.ledger, to: target, groupID: choice.id, plan: plan(payer: payer))
            environment.haptics.play(.settle)
            if (target as AnyObject) === (flow.ledger as AnyObject) {
                await flow.load() // finalized here: the flow shows its success screen
            } else {
                flow.handedOff = .addedToGroup(choice.id, room.id)
            }
        } catch {
            failure = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: flow.snapshot?.members ?? [:])
        }
    }
}

// MARK: - Split with people now

/// A temporary room: no group, the person who scanned paid, and everyone else joins by QR code,
/// link, or short code. After the split is final, people pay them back and they confirm.
struct SplitNowView: View {
    let flow: ReceiptFlowModel
    @Environment(AppEnvironment.self) private var environment
    @State private var chosenMethods: Set<String> = []
    @State private var sharesPhoto = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var loaded = false

    private var methods: [DestinationDTO] { (environment.sharedGroups.profile?.destinations ?? []).filter(\.isEnabled) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                SUHeadline(primary: String(localized: "Split with people now"),
                           secondary: String(localized: "No group needed. Everyone joins on their own phone."))
                if !environment.sharing.isConfigured {
                    SUConfirmationBanner(title: String(localized: "Not available in this build"),
                                         message: String(localized: "Splitting with people now needs Square Up's server. Add the receipt to a group on this iPhone instead."),
                                         systemImage: "icloud.slash", tone: .warning)
                }
                if let room = flow.room { payerPanel(room) }
                methodsPanel
                photoPanel
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    Label(String(localized: "People see the merchant, items, amounts, and who claimed what — never your groups or balances."),
                          systemImage: "eye")
                    Label(String(localized: "Square Up never moves money. People pay you however you choose, and you confirm when it arrives."),
                          systemImage: "hand.raised")
                    Label(String(localized: "The room closes once everyone has paid and you've confirmed it, or if it expires."), systemImage: "clock")
                }
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                if let failure {
                    SUConfirmationBanner(title: String(localized: "Room not created"), message: failure, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                        .accessibilityIdentifier("splitNow.error")
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .padding(.bottom, 140)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Split now"))
        .safeAreaInset(edge: .bottom) { createBar }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chosenMethods = Set(methods.map(\.id))
        }
    }

    private func payerPanel(_ room: ReceiptRoom) -> some View {
        SUCoverPanel(palette: .attention, symbol: "qrcode", coverHeight: 150) {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUCoverChip(lead: .symbol("person.fill.checkmark", .white), title: String(localized: "You paid"),
                            subtitle: String(localized: "Everyone else pays you back"))
                Spacer(minLength: SUSpacing.sm)
                Text(room.title).font(SUFont.cardTitle).foregroundStyle(.white).lineLimit(2)
                if let total = room.receipt.total.value {
                    Text(MoneyFormatting.string(total)).font(SUFont.heroAmount).foregroundStyle(.white).minimumScaleFactor(0.6)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var methodsPanel: some View {
        SUPanelSection(title: String(localized: "How people can pay you"),
                       subtitle: String(localized: "Shown only to people who owe you, after you finish the split.")) {
            if methods.isEmpty {
                Text(String(localized: "You haven't added a payment method. People can still pay you in cash or however you agree; add methods in Profile → How friends pay you."))
                    .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
            } else {
                ForEach(methods, id: \.id) { method in
                    let provider = PaymentProviderKind(rawValue: method.provider)
                    Toggle(isOn: Binding(get: { chosenMethods.contains(method.id) }, set: { on in
                        if on { chosenMethods.insert(method.id) } else { chosenMethods.remove(method.id) }
                    })) {
                        Label(method.label ?? provider?.displayName ?? method.provider, systemImage: provider?.symbolName ?? "creditcard")
                            .font(SUFont.body)
                    }
                    .accessibilityIdentifier("splitNow.method.\(method.provider)")
                }
            }
        }
    }

    private var photoPanel: some View {
        SUPanelSection(title: String(localized: "Receipt photo")) {
            Toggle(isOn: $sharesPhoto) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Show the photo to people in the room")).font(SUFont.body)
                    Text(sharesPhoto ? String(localized: "Only people in this room can see it. It's deleted with the room.")
                        : String(localized: "Off: the photo stays on this iPhone. People see the items and amounts."))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            .disabled(flow.room?.receipt.activePages.isEmpty ?? true)
            .accessibilityIdentifier("splitNow.photo")
        }
    }

    private var createBar: some View {
        VStack(spacing: SUSpacing.xs) {
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if isWorking { ProgressView() }
                    Label(String(localized: "Create room and invite"), systemImage: "qrcode")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .disabled(isWorking || !environment.sharing.isConfigured)
            .accessibilityIdentifier("splitNow.create")
            Button(String(localized: "Back")) { flow.show(.choosing) }.buttonStyle(.suSecondary(fullWidth: true))
        }
        .padding(SUSpacing.md)
        .background(.bar)
    }

    private func create() async {
        guard let room = flow.room else { return }
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let chosen = methods.map(\.id).filter(chosenMethods.contains)
            try await environment.sharing.startTemporaryRoom(room.id, destinationIDs: chosen)
            if sharesPhoto {
                // Best effort: the room works without the photo, and it's never uploaded unless chosen.
                for page in room.receipt.activePages {
                    if let jpeg = await Self.jpeg(page, store: environment.receipts.assets) {
                        try? await environment.sharing.shareReceiptPhoto(jpeg, roomID: room.id)
                    }
                }
            }
            environment.sharing.inviteOnOpen = room.id
            flow.handedOff = .temporaryRoom(room.id)
        } catch {
            failure = LedgerErrorMessages.text(for: error)
        }
    }

    /// The page as a JPEG small enough to share (the server removes any metadata again).
    static func jpeg(_ page: ReceiptAsset, store: any ReceiptAssetStoring) async -> Data? {
        guard let image = try? await store.image(named: page.pageFileName, maxPixel: 2400) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else { return nil }
        return data as Data
    }
}
