import SwiftUI

/// The full-screen receipt experience: source → processing → review → room setup → room →
/// final review → success. Each step is derived from persisted state, so it resumes after relaunch.
struct ReceiptFlowView: View {
    let request: ReceiptFlowRequest
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ReceiptFlowContainer(model: ReceiptFlowModel(environment: environment, request: request))
    }
}

private struct ReceiptFlowContainer: View {
    /// The local flow: capture, review, setup, and unshared rooms.
    @State private var local: ReceiptFlowModel
    /// Milestone 4: once the room is shared, the same screens run on its live session.
    @State private var shared: ReceiptFlowModel?
    @State private var isConfirmingClose = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ReceiptFlowModel) {
        _local = State(initialValue: model)
        _shared = State(initialValue: Self.sharedModel(for: model))
    }

    private var model: ReceiptFlowModel { shared ?? local }

    private var sharedRoomID: ReceiptRoomID? {
        local.roomID.flatMap { local.environment.sharing.isShared($0) ? $0 : nil }
    }

    /// The live session's flow: a room this device hosts or joined, or one of a shared group's
    /// receipts (opened from the group, or just posted from this flow).
    private static func sharedModel(for local: ReceiptFlowModel) -> ReceiptFlowModel? {
        guard let id = local.roomID else { return nil }
        if case .addedToGroup(let groupID, let roomID)? = local.handedOff {
            return ReceiptFlowModel(environment: local.environment.environment(for: groupID), request: ReceiptFlowRequest(start: .resume(roomID)))
        }
        if let groupID = local.groupReceiptGroupID {
            let environment = local.environment.environment(for: groupID)
            guard let ledger = environment.sharedGroups.ledger(for: groupID) else { return nil }
            let sharing = environment.sharing
            let session = ledger.receiptSession(id) { await sharing.localDraftContext(id) }
            return ReceiptFlowModel(environment: environment.shared(session), request: ReceiptFlowRequest(start: .resume(id)))
        }
        guard let session = local.environment.sharing.session(for: id) else { return nil }
        return ReceiptFlowModel(environment: local.environment.shared(session), request: ReceiptFlowRequest(start: .resume(id)))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if model.step == .processing {
                            // The processing screen is only the ring: Back is the one way out.
                            Button { Task { await model.leaveProcessing() } } label: {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                            }
                            .accessibilityLabel(String(localized: "Back"))
                            .accessibilityIdentifier("receipt.processingBack")
                        } else {
                            Button(String(localized: "Close")) { close() }
                                .accessibilityIdentifier("receipt.close")
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let session = model.remote, model.room != nil {
                        SharedRoomStatusBar(flow: model, session: session)
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: model.step)
        }
        .environment(model.environment)
        .sheet(item: sheetBinding, onDismiss: openInvitationAfterSharing) { sheet in
            switch sheet {
            case .share(let roomID):
                ShareRoomSheet(roomID: roomID, isPresented: Binding(get: { true }, set: { if !$0 { sharing.sheet = nil } }))
            case .invite(let roomID):
                InviteSheet(roomID: roomID)
            }
        }
        .task { await local.load() }
        .task(id: model.environment.ledger.revision) { await model.load() }
        .onChange(of: model.announcements.count) {
            // Stage changes and the processing result (milestone 5 §"Processing interface").
            if let text = model.announcements.last { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: sharedRoomID) { connectShared() }
        .onChange(of: local.handedOff) { connectShared() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Poll only while the room is on screen and the app is active (milestone 4 §7.3).
            if phase == .active { shared?.remote?.startPolling() } else { shared?.remote?.stopPolling() }
        }
        .onDisappear { shared?.remote?.stopPolling() }
        .confirmationDialog(String(localized: "Keep this receipt?"), isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button(String(localized: "Save draft")) { dismiss() }
            Button(String(localized: "Discard receipt"), role: .destructive) {
                Task { if await model.discardDraft() { dismiss() } }
            }
            Button(String(localized: "Keep reviewing"), role: .cancel) {}
        } message: {
            Text(String(localized: "A saved draft keeps its images and edits on this iPhone. Discarding deletes them."))
        }
    }

    private var sharing: SharingService { local.environment.sharing }

    private var sheetBinding: Binding<SharingService.RoomSheet?> {
        Binding(get: { sharing.sheet }, set: { sharing.sheet = $0 })
    }

    /// Just published: show the invitation once the sharing sheet is fully gone.
    private func openInvitationAfterSharing() {
        guard let roomID = sharing.inviteOnOpen else { return }
        sharing.inviteOnOpen = nil
        sharing.sheet = .invite(roomID)
    }

    /// After publishing, starting a temporary room, or posting to a group from this flow, continue
    /// on the live session — and for a new temporary room, show its invitation right away.
    private func connectShared() {
        if shared == nil, let model = Self.sharedModel(for: local) {
            shared = model
            model.remote?.startPolling()
        }
        // The room can connect (it's now in the directory) before the flow hands off; whichever
        // happens last opens the invitation.
        if shared != nil, let id = local.roomID, sharing.inviteOnOpen == id {
            sharing.inviteOnOpen = nil
            sharing.sheet = .invite(id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.remote != nil, model.room == nil {
            SharedRoomLoadingView(flow: model) { dismiss() }
        } else {
            stepContent
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .source:
            ReceiptSourceView(model: model)
        case .processing:
            ReceiptProcessingView(model: model)
        case .review:
            if let room = model.room, let snapshot = model.snapshot {
                ReceiptReviewView(flow: model, review: ReceiptReviewModel(room: room, snapshot: snapshot, now: model.environment.now))
                    .id(room.id)
            }
        case .choosePath:
            ChoosePathView(flow: model)
        case .addToGroup:
            AddToGroupView(flow: model)
        case .splitNow:
            SplitNowView(flow: model)
        case .setup:
            RoomSetupView(flow: model)
        case .room:
            ReceiptRoomView(flow: model)
        case .finalReview:
            FinalReviewView(flow: model)
        case .finished(let expenseID):
            ReceiptSuccessView(flow: model, expenseID: expenseID) { router.finishReceipt(showing: expenseID) }
        case .sharedResult:
            if model.remote?.isTemporary == true {
                TemporaryRoomSettleView(flow: model) { dismiss() }
            } else {
                SharedRoomResultView(flow: model) { dismiss() }
            }
        case .closed:
            SUEmptyState(systemImage: "xmark.circle", title: String(localized: "This receipt is closed"),
                         message: String(localized: "It was cancelled, so no expense was created."),
                         primaryTitle: String(localized: "Done")) { dismiss() }
                .frame(maxHeight: .infinity)
                .suScreenBackground()
        }
    }

    /// Leaving never loses work: drafts can be kept or discarded; rooms stay open for later.
    private func close() {
        switch model.step {
        case .processing:
            model.cancelRecognition()
            isConfirmingClose = true
        case .review, .choosePath, .addToGroup, .splitNow:
            isConfirmingClose = true
        default:
            dismiss()
        }
    }
}

/// Step 1: choose how to bring in the receipt (milestone 3 §5.2).
struct ReceiptSourceView: View {
    let model: ReceiptFlowModel
    @State private var isImporting = false
    @State private var notice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isImporting {
            // The processing ring starts as soon as a receipt is chosen and runs until it's read.
            ReceiptRingScreen(spokenStatus: String(localized: "Reading your receipt. \(ReceiptProcessingStage.preparing.title)"),
                              isAnimated: model.environment.allowsAmbientAnimation && !reduceMotion)
        } else {
            choices
        }
    }

    private var choices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                VStack(alignment: .leading, spacing: SUSpacing.xs) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(SUColor.accent)
                        .accessibilityHidden(true)
                    Text(String(localized: "Split a receipt"))
                        .font(SUFont.screenTitle)
                        .foregroundStyle(SUColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "Scan or import it, check what Square Up read, then let everyone claim what they had."))
                        .font(SUFont.body)
                        .foregroundStyle(SUColor.textSecondary)
                }
                if let group = model.initialGroupID.flatMap({ model.snapshot?.group($0) }) {
                    Label(String(localized: "For \(group.name)"), systemImage: group.symbolName)
                        .font(SUFont.supporting.weight(.semibold))
                        .foregroundStyle(SUColor.textPrimary)
                }

                ReceiptCaptureControls { images, source in store(images, source) }

                if let message = notice ?? model.errorMessage {
                    SUConfirmationBanner(title: String(localized: "Check this"), message: message, systemImage: "exclamationmark.triangle.fill", tone: .warning)
                }

                savedReceipts

                SharedRoomsSection { id in model.resume(id) }

                // UI tests only: a fictional receipt with prerecorded text recognition. Never shown to people.
                if model.environment.configuration.isUITesting {
                    Button {
                        useSample()
                    } label: {
                        Label(String(localized: "Use the sample receipt"), systemImage: "doc.text.image").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.suSecondary)
                    .disabled(isImporting || SampleReceipt.imageURL == nil)
                    .accessibilityIdentifier("receipt.sample")
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Scan receipt"))
    }

    @ViewBuilder
    private var savedReceipts: some View {
        // Receipts posted to a group or splitting live open from their group or Home, not here.
        let rooms = (model.snapshot?.unfinishedRooms ?? []).filter { model.environment.place(of: $0.id) == .draft }
        if !rooms.isEmpty, let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUSectionHeader(title: String(localized: "Continue a saved receipt"))
                ForEach(rooms) { room in
                    UnfinishedReceiptRow(room: room, groupName: room.groupID.flatMap(snapshot.group)?.name) {
                        model.resume(room.id)
                    }
                }
            }
        }
    }

    private func store(_ images: [Data], _ source: ReceiptImportSource) {
        isImporting = true
        notice = nil
        Task {
            let result = await model.storePages(images, source: source)
            if result.duplicates > 0 {
                notice = Inflect.string("Skipped ^[\(result.duplicates) page](inflect: true) imported twice.")
            }
            await model.start(with: result.pages)
            isImporting = false
        }
    }

    private func useSample() {
        guard let url = SampleReceipt.imageURL, let data = try? Data(contentsOf: url) else { return }
        store([data], .sample)
    }
}

/// A draft or room still in progress, with its state in words.
struct UnfinishedReceiptRow: View {
    let room: ReceiptRoom
    let groupName: String?
    /// Where it is now, when that isn't the draft's own state ("Posted to Coastal Weekend").
    var status: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: ReceiptLanguage.symbol(room.state))
                    .font(.title3)
                    .foregroundStyle(SUColor.accent)
                    .frame(width: 40, height: 40)
                    .background(SUColor.accent.opacity(0.14), in: SUShape.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.title).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Spacer(minLength: SUSpacing.xs)
                if let total = room.receipt.total.value {
                    SUAmountView(money: total, direction: .muted, style: .small)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SUSpacing.sm)
            .suSurface(SUShape.compact)
            .contentShape(SUShape.compact)
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receipt.unfinished")
    }

    private var detail: String {
        if let status { return status }
        var parts = [ReceiptLanguage.label(room.state)]
        if let groupName { parts.append(groupName) }
        return parts.joined(separator: " · ")
    }
}

extension ReceiptFlowModel {
    func resume(_ id: ReceiptRoomID) {
        Task {
            await switchTo(id)
        }
    }
}
