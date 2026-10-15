import Foundation
import OSLog

/// The named stages shown while processing (milestone 3 §5.3; milestone 5 renames the third to
/// match what happens with or without AI processing).
nonisolated enum ReceiptProcessingStage: Int, CaseIterable, Sendable, Comparable {
    case preparing
    case reading
    case understanding
    case checking

    static func < (lhs: ReceiptProcessingStage, rhs: ReceiptProcessingStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .preparing: String(localized: "Preparing receipt")
        case .reading: String(localized: "Reading text")
        case .understanding: String(localized: "Understanding items")
        case .checking: String(localized: "Checking totals")
        }
    }
}

nonisolated struct ReceiptProcessingUpdate: Equatable, Sendable {
    let stage: ReceiptProcessingStage
    let completedPages: Int
    let pageCount: Int
}

/// Recognize → structure → validate (milestone 3 §6.1 stages 3–5), off the main actor, with a
/// cancellation check between every stage and page. Failure never loses the draft: recognition
/// problems return a reviewable draft marked failed so the person can retry or enter it by hand.
///
/// Milestone 5: Vision always runs. With the `.cloud` route, AI processing structures the receipt
/// from the page images and Vision's evidence; any failure uses the on-device structurer and
/// records why (`RecognitionInfo.fallback`).
nonisolated struct ReceiptPipeline: Sendable {
    let assets: any ReceiptAssetStoring
    let fileURL: @Sendable (String) -> URL
    let recognizer: any ReceiptRecognizing
    let sampleRecognizer: any ReceiptRecognizing
    let structurer: any ReceiptStructuring
    let fallbackStructurer: any ReceiptStructuring = DeterministicReceiptStructurer()

    @concurrent
    func process(
        _ draft: ReceiptDraft,
        defaultCurrency: CurrencyCode,
        seed: UUID,
        route: ReceiptStructuringRoute = .onDevice(nil),
        progress: @escaping @Sendable (ReceiptProcessingUpdate) async -> Void
    ) async throws -> ReceiptDraft {
        let clock = ContinuousClock()
        let started = clock.now
        let pages = draft.activePages
        var result = draft

        await progress(ReceiptProcessingUpdate(stage: .preparing, completedPages: 0, pageCount: pages.count))
        for page in pages where await !(assets.fileExists(page.pageFileName)) {
            throw ReceiptAssetError.missingFile
        }
        try Task.checkCancellation()

        var regions: [RecognizedRegion] = []
        var provider: RecognitionProviderKind = .onDeviceDeterministic
        for (index, page) in pages.enumerated() {
            await progress(ReceiptProcessingUpdate(stage: .reading, completedPages: index, pageCount: pages.count))
            let recognizer = page.source == .sample ? sampleRecognizer : recognizer
            if recognizer.kind == .fixture { provider = .fixture }
            let pageSeed = DerivedID.make(seed, 10_000 * (index + 1))
            regions += try await recognizer.recognize(page: page, imageURL: fileURL(page.pageFileName), seed: pageSeed)
            try Task.checkCancellation()
        }

        await progress(ReceiptProcessingUpdate(stage: .understanding, completedPages: pages.count, pageCount: pages.count))
        let input = ReceiptStructuringInput(pages: pages, regions: regions, defaultCurrency: defaultCurrency,
                                            captureDate: draft.createdAt, idSeed: seed)
        var fallback: ReceiptIntelligenceFallback?
        var cloud: CloudProcessingInfo?
        var cloudProposal: ReceiptProposal?
        switch route {
        case .onDevice(let reason):
            fallback = reason
        case .cloud(let structurer):
            do {
                (cloudProposal, cloud) = try await structurer.structure(input)
                provider = .cloudModel
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallback = error as? ReceiptIntelligenceFallback ?? .invalidResponse
                Log.receipts.info("AI processing unavailable (\(fallback?.rawValue ?? "-", privacy: .public)); using on-device parsing")
            }
        }
        try Task.checkCancellation()
        let proposal: ReceiptProposal
        if let cloudProposal {
            proposal = cloudProposal
        } else {
            do {
                proposal = try await structurer.structure(input)
                if structurer.kind == .onDeviceModel, provider != .fixture { provider = .onDeviceModel }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An optional provider failing never blocks the workflow.
                Log.receipts.info("Structurer fell back to deterministic rules")
                proposal = try await fallbackStructurer.structure(input)
            }
        }
        try Task.checkCancellation()

        await progress(ReceiptProcessingUpdate(stage: .checking, completedPages: pages.count, pageCount: pages.count))
        result.regions = regions
        result = proposal.applied(to: result)
        for index in result.pages.indices {
            let pageRegions = regions.filter { $0.pageID == result.pages[index].id }
            if ImageQualityAnalyzer.edgeWarning(for: pageRegions), !result.pages[index].qualityWarnings.contains(.edgesMissing) {
                result.pages[index].qualityWarnings.append(.edgesMissing)
            }
        }
        let milliseconds = (clock.now - started).components
        result.recognition.provider = provider
        result.recognition.fallback = fallback
        result.recognition.cloud = cloud
        result.recognition.regionCount = regions.count
        result.recognition.durationMilliseconds = Int(milliseconds.seconds * 1000 + milliseconds.attoseconds / 1_000_000_000_000_000)
        result.recognition.status = regions.isEmpty ? .failed(.noText) : .completed
        Log.receipts.info("""
        Recognition finished: \(pages.count, privacy: .public) pages, \(regions.count, privacy: .public) regions, \
        \(result.recognition.durationMilliseconds ?? 0, privacy: .public) ms, provider \(provider.rawValue, privacy: .public)
        """)
        return result
    }
}
