import Foundation
import Observation
import OSLog

/// Navigation and lifecycle for one receipt, from capture to finalization.
///
/// The step is derived from the persisted room state, so relaunching mid-flow resumes at the
/// right screen. Recognition runs in a cancellable task off the main actor; the draft is saved
/// before recognition starts, so closing the app never loses the captured pages.
@Observable
final class ReceiptFlowModel {
    enum Step: Equatable {
        case source
        case processing
        case review
        /// The receipt is reviewed: add it to a group, or split it with people now.
        case choosePath
        /// Choose a group, the people who were there, and who paid.
        case addToGroup
        /// Start a temporary room: no group, the scanner paid, everyone joins by invitation.
        case splitNow
        case setup
        case room
        case finalReview
        case finished(ExpenseID)
        /// Milestone 4: a shared room finalized by its host, seen by a participant (no local expense).
        /// For a temporary room, everyone settles up here.
        case sharedResult
        case closed
    }

    /// Where a reviewed draft is going. Only on screen: a relaunch resumes at review.
    enum DraftStage: Equatable {
        case review
        case choosing
        case addToGroup
        case splitNow
    }

    let environment: AppEnvironment
    let initialGroupID: GroupID?
    private(set) var roomID: ReceiptRoomID?
    private(set) var room: ReceiptRoom?
    private(set) var snapshot: LedgerSnapshot?
    private(set) var step: Step = .source
    private(set) var progress: ReceiptProcessingUpdate?
    private(set) var isProcessing = false
    var errorMessage: String?
    /// PROTOTYPE: who is acting in the room on this device ("Previewing as …"). Never grants host rights.
    var actingMemberID: MemberID?
    /// Milestone 5: the AI-processing disclosure is waiting for the person's choice.
    private(set) var isAskingForAIConsent = false
    /// Whether the current processing run is trying AI processing (shown in the processing copy).
    private(set) var isUsingAIProcessing = false
    /// VoiceOver announcements (stage changes, the result). The view posts each new one.
    private(set) var announcements: [String] = []
    /// After review: choosing a path, or one of the two paths.
    private(set) var draftStage: DraftStage = .review
    /// A receipt this flow just posted to a shared group or started as a temporary room; the
    /// container continues on its live session.
    var handedOff: HandOff?

    enum HandOff: Equatable {
        case groupReceipt(GroupID, ReceiptRoomID)
        case temporaryRoom(ReceiptRoomID)
        /// "Add to a group" finished it as an expense in a group whose receipts another ledger keeps
        /// (a shared group): the flow continues there, on its success screen.
        case addedToGroup(GroupID, ReceiptRoomID)
    }

    @ObservationIgnored private var processingTask: Task<Void, Never>?
    /// The receipt being read was imported just now (Back discards it), not re-read from its review.
    @ObservationIgnored private var isReadingNewImport = false
    @ObservationIgnored private var isLeavingProcessing = false
    @ObservationIgnored private var commandQueue: Task<LedgerCommandResult?, Never>?

    init(environment: AppEnvironment, request: ReceiptFlowRequest) {
        self.environment = environment
        switch request.start {
        case .new(let groupID):
            initialGroupID = groupID
        case .resume(let id):
            initialGroupID = nil
            roomID = id
        case .groupReceipt(let groupID, let id):
            initialGroupID = groupID
            roomID = id
            handedOff = .groupReceipt(groupID, id)
        }
    }

    /// The shared group whose receipt this flow shows (opened from the group, or just posted).
    var groupReceiptGroupID: GroupID? {
        if case .groupReceipt(let groupID, _)? = handedOff { groupID } else { nil }
    }

    var ledger: any LedgerStore { environment.ledger }
    /// The live session when this flow shows a shared room (milestone 4).
    var remote: RemoteRoomLedger? { environment.remoteRoom }
    var currentUserID: MemberID? { snapshot?.currentUserID }
    var actor: MemberID? { actingMemberID ?? currentUserID }
    var isHostActing: Bool { actor != nil && actor == room?.hostID }
    var group: ExpenseGroup? { room?.groupID.flatMap { snapshot?.group($0) } }

    // MARK: Loading

    func load() async {
        do {
            let snapshot = try await ledger.snapshot()
            self.snapshot = snapshot
            if let roomID {
                room = snapshot.room(roomID)
                if actingMemberID == nil, let room { actingMemberID = snapshot.currentUserID == room.hostID ? room.hostID : snapshot.currentUserID }
            }
            if !isProcessing { step = currentStep() }
        } catch {
            errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
        }
    }

    private func currentStep() -> Step {
        let step = Self.step(for: room, remote: remote)
        guard step == .review else { return step }
        switch draftStage {
        case .review: return .review
        case .choosing: return .choosePath
        case .addToGroup: return .addToGroup
        case .splitNow: return .splitNow
        }
    }

    /// Moves between the review and the two ways of splitting a reviewed receipt.
    func show(_ stage: DraftStage) {
        errorMessage = nil
        draftStage = stage
        step = currentStep()
    }

    static func step(for room: ReceiptRoom?, remote: RemoteRoomLedger? = nil) -> Step {
        guard let room else { return .source }
        if let remote {
            if remote.isTemporary {
                // A temporary room ends in its own summary: people pay the payer, who confirms.
                switch room.state {
                case .readyToFinalize where !remote.isHost: return .room
                case .finalized, .cancelled: return .sharedResult
                default: break
                }
            }
            switch room.state {
            case .readyToFinalize where !remote.isHost: return .room
            case .finalized: return room.finalExpenseID.map(Step.finished) ?? .sharedResult
            default: break
            }
        }
        switch room.state {
        case .draft: return .review
        case .ready: return .setup
        case .open, .resolving: return .room
        case .readyToFinalize: return .finalReview
        case .finalized: return room.finalExpenseID.map(Step.finished) ?? .closed
        case .cancelled: return .closed
        }
    }

    // MARK: Commands

    /// Runs a room command as the acting participant (or the host for host commands) and reloads.
    @discardableResult
    func run(_ command: ReceiptRoomCommand, asHost: Bool = false) async -> LedgerCommandResult? {
        do {
            let actorID = asHost ? room?.hostID : actor
            let result = try await ledger.run(command, as: actorID)
            errorMessage = nil
            await load()
            return result
        } catch {
            errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: snapshot?.members ?? [:])
            await load()
            return nil
        }
    }

    /// Quick, repeated taps on this device (claim, share, undo) run one after another, each against
    /// the room as it is after the previous one — so a person's own taps never collide. Commands
    /// built from an editor's view keep the revision that view was based on.
    @discardableResult
    func runInSequence(asHost: Bool = false, _ make: @escaping (ReceiptRoom) -> ReceiptRoomCommand) async -> LedgerCommandResult? {
        let previous = commandQueue
        let task = Task { () -> LedgerCommandResult? in
            _ = await previous?.value
            guard let room = self.room else { return nil }
            return await self.run(make(room), asHost: asHost)
        }
        commandQueue = task
        return await task.value
    }

    // MARK: Capture and recognition

    /// Creates the draft from stored pages, then recognizes it.
    func start(with pages: [ReceiptAsset]) async {
        guard !pages.isEmpty else { return }
        let snapshot = try? await ledger.snapshot()
        let currency = initialGroupID.flatMap { snapshot?.group($0)?.currency } ?? snapshot?.defaultCurrency ?? .usd
        let id = ReceiptRoomID()
        do {
            try await ledger.run(.createDraft(id, groupID: initialGroupID, pages: pages, currency: currency), as: nil)
        } catch {
            // Nothing references the files yet; remove them so a failed save leaves no orphans.
            await environment.receipts.assets.delete(pages)
            errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
            return
        }
        roomID = id
        await load()
        isReadingNewImport = true
        recognize()
    }

    /// Back from the processing screen. A receipt imported just now is set aside — reading stops, the
    /// draft and its images go — and the choice of how to bring one in returns. A receipt re-read from
    /// its review keeps everything: reading stops and the review returns.
    func leaveProcessing() async {
        guard isReadingNewImport else {
            cancelRecognition()
            return
        }
        isLeavingProcessing = true
        defer { isLeavingProcessing = false }
        let task = processingTask
        task?.cancel()
        await task?.value
        isAskingForAIConsent = false
        isProcessing = false
        _ = await discardDraft()
        isReadingNewImport = false
        errorMessage = nil
        await load()
        step = .source
    }

    /// Recognizes (or re-recognizes) the draft's pages. Cancellable; the draft is never lost.
    /// Milestone 5: the first time AI processing could be used, the disclosure is shown first.
    func recognize() {
        guard let room, room.state == .draft else { return }
        if environment.receiptIntelligence != nil, environment.receiptAI.mode == .undecided {
            isProcessing = true
            step = .processing
            progress = ReceiptProcessingUpdate(stage: .preparing, completedPages: 0, pageCount: room.receipt.activePages.count)
            isAskingForAIConsent = true
            return
        }
        startRecognition(route: structuringRoute())
    }

    /// The person answered the disclosure (`nil`: they dismissed it without choosing — this
    /// receipt stays on the device and they're asked again next time).
    func resolveAIConsent(_ choice: ReceiptAIMode?) {
        guard isAskingForAIConsent else { return }
        isAskingForAIConsent = false
        if let choice { environment.receiptAI.choose(choice) }
        startRecognition(route: choice == nil ? .onDevice(.notConsented) : structuringRoute())
    }

    /// AI processing only with consent, a configured server, and no known loss of connectivity.
    func structuringRoute() -> ReceiptStructuringRoute {
        guard let service = environment.receiptIntelligence else { return .onDevice(nil) }
        switch environment.receiptAI.mode {
        case .onDeviceOnly: return .onDevice(.onDeviceOnly)
        case .undecided: return .onDevice(.notConsented)
        case .automatic:
            if environment.connectivity.isOffline { return .onDevice(.offline) }
            return .cloud(CloudReceiptStructurer(service: service, fileURL: environment.receipts.fileURL))
        }
    }

    private func startRecognition(route: ReceiptStructuringRoute) {
        guard let room, room.state == .draft else { return }
        processingTask?.cancel()
        isProcessing = true
        step = .processing
        if case .cloud = route { isUsingAIProcessing = true } else { isUsingAIProcessing = false }
        progress = ReceiptProcessingUpdate(stage: .preparing, completedPages: 0, pageCount: room.receipt.activePages.count)
        announce(ReceiptProcessingStage.preparing.title)
        processingTask = Task { [environment] in
            let activity = BackgroundActivity("Receipt processing") { self.cancelRecognition() }
            defer { activity.end() }
            var marked = room.receipt
            marked.recognition.status = .inProgress
            await run(.saveDraft(room.id, expectedRevision: room.revision, receipt: marked, groupID: room.groupID, payerID: room.payerID))
            let currency = group?.currency ?? room.receipt.currencyCode
            do {
                let result = try await environment.receipts.pipeline.process(
                    marked, defaultCurrency: currency, seed: room.id.rawValue, route: route
                ) { update in
                    await MainActor.run {
                        if self.progress?.stage != update.stage { self.announce(update.stage.title) }
                        self.progress = update
                    }
                }
                try Task.checkCancellation()
                await save(result)
                announce(Self.resultAnnouncement(for: result))
            } catch is CancellationError {
                // Leaving with Back discards the draft next; there's nothing to keep.
                if !isLeavingProcessing {
                    var stopped = self.room?.receipt ?? marked
                    stopped.recognition.status = .skipped
                    await save(stopped)
                }
            } catch {
                var failed = self.room?.receipt ?? marked
                failed.recognition.status = .failed((error as? RecognitionFailure) ?? .unreadableImage)
                await save(failed)
                Log.receipts.error("Recognition failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            isProcessing = false
            isReadingNewImport = false
            progress = nil
            // Leaving: stay on the ring until the draft is gone, then the source returns (no flash of review).
            if !isLeavingProcessing { step = Self.step(for: self.room, remote: remote) }
        }
    }

    func cancelRecognition() {
        processingTask?.cancel()
    }

    func announce(_ text: String) {
        announcements.append(text)
    }

    /// What VoiceOver hears when processing finishes: the outcome and how many problems remain.
    static func resultAnnouncement(for receipt: ReceiptDraft) -> String {
        var parts = [String(localized: "Receipt ready to review.")]
        if receipt.recognition.fallback?.showsNotice == true { parts.append(ReceiptLanguage.preparedOnDevice(receipt.recognition.fallback)) }
        let blocking = ReceiptValidator.reconcile(receipt).blockingIssues.count
        if blocking > 0 { parts.append(Inflect.string("^[\(blocking) problem](inflect: true) to resolve.")) }
        return parts.joined(separator: " ")
    }

    private func save(_ receipt: ReceiptDraft) async {
        guard let room else { return }
        await run(.saveDraft(room.id, expectedRevision: room.revision, receipt: receipt, groupID: room.groupID, payerID: room.payerID))
    }

    /// Stores captured or imported images, skipping exact duplicates of pages already present.
    func storePages(_ images: [Data], source: ReceiptImportSource, existing: [ReceiptAsset] = []) async -> (pages: [ReceiptAsset], duplicates: Int) {
        var stored: [ReceiptAsset] = []
        var duplicates = 0
        var failures = 0
        for data in images {
            do {
                let asset = try await environment.receipts.assets.importImage(data, id: ReceiptAssetID(), source: source, createdAt: environment.now)
                if (existing + stored).contains(where: { $0.fingerprint == asset.fingerprint && !$0.isRemoved }) {
                    duplicates += 1
                    await environment.receipts.assets.delete([asset])
                } else {
                    stored.append(asset)
                }
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            errorMessage = failures == images.count
                ? String(localized: "That image couldn't be opened. Try another photo or scan the receipt.")
                : Inflect.string("^[\(failures) image](inflect: true) couldn't be opened and was skipped.")
        }
        return (stored, duplicates)
    }

    /// Previews and snapshot tests: show the processing screen at a given stage.
    func showProcessingState(_ update: ReceiptProcessingUpdate) {
        isProcessing = true
        step = .processing
        progress = update
    }

    /// Continues a different saved receipt in this flow.
    func switchTo(_ id: ReceiptRoomID) async {
        roomID = id
        actingMemberID = nil
        errorMessage = nil
        draftStage = .review
        await load()
    }

    // MARK: Leaving

    /// Deletes a never-opened draft and its image files.
    func discardDraft() async -> Bool {
        guard let room else { return true }
        processingTask?.cancel()
        guard await run(.discardDraft(room.id), asHost: true) != nil else { return false }
        await environment.receipts.assets.delete(room.receipt.pages)
        return true
    }
}
