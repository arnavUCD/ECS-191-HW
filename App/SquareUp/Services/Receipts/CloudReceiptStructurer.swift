import Foundation
import OSLog

/// How the pipeline should structure a receipt (milestone 5 §3.1).
nonisolated enum ReceiptStructuringRoute: Sendable {
    /// The on-device parser. A reason is recorded when AI processing was chosen against or was
    /// intended but not possible; `nil` means AI isn't part of this build (milestone 3 behaviour).
    case onDevice(ReceiptIntelligenceFallback?)
    /// Try AI processing first; any failure falls back to the on-device parser.
    case cloud(CloudReceiptStructurer)
}

/// Builds the request from Vision's evidence and the page images, calls the server with a
/// deadline, and maps the answer through `ReceiptIntelligenceMapper`. Throws a
/// `ReceiptIntelligenceFallback` for every failure, or `CancellationError` when the person stops.
nonisolated struct CloudReceiptStructurer: Sendable {
    static let maximumPages = 6
    static let maximumRegions = 1500
    static let maximumRegionText = 300
    static let consentVersion = 1

    let service: any ReceiptIntelligenceServicing
    /// The processing image for a page (metadata-free, size-limited JPEG).
    let pageImage: @Sendable (ReceiptAsset) async throws -> Data
    var localeIdentifier: String? = Locale.current.identifier
    var deadline: Duration = .seconds(60)

    init(service: any ReceiptIntelligenceServicing, fileURL: @escaping @Sendable (String) -> URL) {
        self.service = service
        pageImage = { page in try ReceiptImageProcessing.processingJPEG(at: fileURL(page.pageFileName)) }
    }

    init(service: any ReceiptIntelligenceServicing, pageImage: @escaping @Sendable (ReceiptAsset) async throws -> Data) {
        self.service = service
        self.pageImage = pageImage
    }

    func structure(_ input: ReceiptStructuringInput) async throws -> (ReceiptProposal, CloudProcessingInfo) {
        let clock = ContinuousClock()
        let started = clock.now
        let request = try await makeRequest(input)
        try Task.checkCancellation()
        let response = try await withDeadline { try await service.parse(request) }
        let proposal: ReceiptProposal
        do {
            proposal = try ReceiptIntelligenceMapper.proposal(from: response, input: input)
        } catch {
            Log.receipts.notice("AI processing response rejected on device")
            throw ReceiptIntelligenceFallback.invalidResponse
        }
        let elapsed = (clock.now - started).components
        let info = CloudProcessingInfo(
            schemaVersion: response.schemaVersion, cached: response.cached,
            durationMilliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
            overallConfidence: ReceiptIntelligenceMapper.overallConfidence(response.proposal.overallConfidence)
        )
        return (proposal, info)
    }

    /// Vision's regions and the page images, in page order. Only what Claude needs (§4).
    func makeRequest(_ input: ReceiptStructuringInput) async throws -> ReceiptIntelligenceDTO.Request {
        guard (1...Self.maximumPages).contains(input.pages.count) else { throw ReceiptIntelligenceFallback.ineligible }
        var pages: [ReceiptIntelligenceDTO.Request.Page] = []
        for (index, page) in input.pages.enumerated() {
            let image: Data
            do {
                image = try await pageImage(page)
            } catch {
                throw ReceiptIntelligenceFallback.ineligible
            }
            try Task.checkCancellation()
            pages.append(.init(index: index, image: image, warnings: page.qualityWarnings.map(\.rawValue)))
        }
        let pageIndex = Dictionary(uniqueKeysWithValues: input.pages.enumerated().map { ($1.id, $0) })
        let regions = input.regions.compactMap { region -> ReceiptIntelligenceDTO.Request.Region? in
            guard let page = pageIndex[region.pageID] else { return nil }
            let bounds = region.bounds
            return .init(
                id: region.id.rawValue.uuidString, page: page, order: region.readingOrder,
                text: String(region.text.prefix(Self.maximumRegionText)), confidence: min(max(region.confidence, 0), 1),
                box: [bounds.x, bounds.y, bounds.width, bounds.height].map { min(max($0, 0), 1) },
                alternatives: region.alternatives.prefix(2).map { String($0.prefix(Self.maximumRegionText)) }
            )
        }
        guard regions.count <= Self.maximumRegions else { throw ReceiptIntelligenceFallback.ineligible }
        return ReceiptIntelligenceDTO.Request(
            schemaVersion: ReceiptIntelligenceDTO.schemaVersion,
            consent: .init(mode: "automatic", version: Self.consentVersion),
            locale: localeIdentifier.flatMap(Self.sanitizedLocale), likelyCurrency: input.defaultCurrency.rawValue,
            pages: pages, regions: regions
        )
    }

    /// "en_US@calendar=gregorian" → "en_US" (the server accepts letters, digits, "-" and "_").
    static func sanitizedLocale(_ identifier: String) -> String? {
        let base = identifier.split(separator: "@").first.map(String.init) ?? ""
        let cleaned = String(base.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(35))
        return cleaned.count >= 2 ? cleaned : nil
    }

    private func withDeadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ReceiptIntelligenceFallback.timedOut }
            guard let value = first else { throw ReceiptIntelligenceFallback.timedOut }
            return value
        }
    }
}
