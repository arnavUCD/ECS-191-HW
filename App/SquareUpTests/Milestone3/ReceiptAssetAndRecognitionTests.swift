import CoreGraphics
import Foundation
@testable import SquareUp
import Testing

@Suite("M3 receipt files, quality, and recognition", .serialized)
struct ReceiptAssetAndRecognitionTests {
    private func temporaryStore() -> (ReceiptAssetStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "receipts-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ReceiptAssetStore(directory: directory), directory)
    }

    private func sampleData() throws -> Data {
        try Data(contentsOf: #require(SampleReceipt.imageURL))
    }

    private func files(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    @Test("Import stores original, page, and thumbnail; transforms keep the original; delete removes all three")
    func lifecycle() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try sampleData()
        let id = ReceiptAssetID()
        let asset = try await store.importImage(data, id: id, source: .sample, createdAt: .now)
        #expect(files(in: directory) == Set(asset.fileNames))
        #expect(asset.pixelWidth == 1200)
        #expect(asset.pixelHeight == 1920)
        #expect(asset.fingerprint.count == 64)
        let original = try Data(contentsOf: directory.appending(path: asset.originalFileName))
        #expect(original == data, "The original bytes are preserved exactly")
        let thumbnail = try await store.image(named: asset.thumbnailFileName, maxPixel: 1000)
        #expect(max(thumbnail.width, thumbnail.height) <= ReceiptImageProcessing.thumbnailMaxPixel)

        let rotated = try await store.transform(asset, quarterTurns: 1, crop: nil)
        #expect(rotated.pixelWidth == 1920)
        #expect(rotated.pixelHeight == 1200)
        let cropped = try await store.transform(asset, quarterTurns: 0, crop: ReceiptRect(x: 0.1, y: 0, width: 0.8, height: 0.5))
        #expect(cropped.pixelWidth == 960)
        #expect(cropped.pixelHeight == 960)
        #expect(try Data(contentsOf: directory.appending(path: asset.originalFileName)) == data)

        await store.delete([asset])
        #expect(files(in: directory).isEmpty)
    }

    @Test("Duplicate pages share a fingerprint; corrupt data is rejected without leaving files")
    func duplicatesAndCorruption() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try sampleData()
        let first = try await store.importImage(data, id: ReceiptAssetID(), source: .photos, createdAt: .now)
        let second = try await store.importImage(data, id: ReceiptAssetID(), source: .photos, createdAt: .now)
        #expect(first.fingerprint == second.fingerprint)
        await #expect(throws: ReceiptAssetError.unsupportedImage) {
            try await store.importImage(Data("not an image".utf8), id: ReceiptAssetID(), source: .photos, createdAt: .now)
        }
        #expect(files(in: directory).count == 6)
    }

    @Test("Orphan cleanup removes only unreferenced, settled files it owns")
    func orphans() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .photos, createdAt: .now)
        let orphan = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .photos, createdAt: .now)
        try Data("unrelated".utf8).write(to: directory.appending(path: "notes.txt"))
        // Files newer than the cutoff are never touched (an import may be in flight).
        #expect(await store.removeOrphans(referencedFileNames: Set(kept.fileNames), olderThan: .distantPast) == 0)
        let removed = await store.removeOrphans(referencedFileNames: Set(kept.fileNames), olderThan: .now.addingTimeInterval(60))
        #expect(removed == 3)
        #expect(files(in: directory) == Set(kept.fileNames + ["notes.txt"]))
        #expect(!files(in: directory).contains(orphan.pageFileName))
        await store.removeAll()
        #expect(files(in: directory) == ["notes.txt"], "Reset touches only receipt files")
    }

    @Test("Quality analysis flags dark, flat, and blurry images")
    func quality() {
        let size = 64
        let dark = [UInt8](repeating: 10, count: size * size)
        #expect(ImageQualityAnalyzer.warnings(luminance: dark, width: size, height: size).contains(.tooDark))
        let flat = [UInt8](repeating: 200, count: size * size)
        #expect(ImageQualityAnalyzer.warnings(luminance: flat, width: size, height: size).contains(.lowContrast))
        // Crisp alternating text-like stripes: sharp.
        let sharp = (0..<(size * size)).map { index -> UInt8 in (index / size) % 4 < 2 ? 30 : 230 }
        #expect(ImageQualityAnalyzer.warnings(luminance: sharp, width: size, height: size).isEmpty)
        // A smooth gradient with contrast but no edges: blurry.
        let soft = (0..<(size * size)).map { index -> UInt8 in UInt8(40 + (index / size) * 3) }
        #expect(ImageQualityAnalyzer.warnings(luminance: soft, width: size, height: size) == [.blurry])
        let edge = RecognizedRegion(id: ReceiptRegionID(), pageID: ReceiptFixtures.pageID, text: "cut", confidence: 1,
                                    bounds: ReceiptRect(x: 0.9, y: 0.5, width: 0.1, height: 0.02), readingOrder: 0)
        #expect(ImageQualityAnalyzer.edgeWarning(for: [edge]))
    }

    @Test("The pipeline reports named stages and turns the sample into a reviewable draft")
    func pipeline() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .sample, createdAt: DemoScenario.fixedReferenceDate)
        let pipeline = ReceiptPipeline(
            assets: store, fileURL: { directory.appending(path: $0) }, recognizer: VisionReceiptRecognizer(),
            sampleRecognizer: FixtureReceiptRecognizer(), structurer: DeterministicReceiptStructurer()
        )
        let stages = StageRecorder()
        let draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
        let result = try await pipeline.process(draft, defaultCurrency: .usd, seed: ReceiptFixtures.seed) { await stages.append($0.stage) }
        #expect(await stages.values == [.preparing, .reading, .understanding, .checking])
        #expect(result.recognition.status == .completed)
        #expect(result.recognition.provider == .fixture)
        #expect(result.items.count == 8)
        #expect(result.pages == [page])
    }

    @Test("Cancellation stops the pipeline between stages")
    func cancellation() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .sample, createdAt: .now)
        let pipeline = ReceiptPipeline(assets: store, fileURL: { directory.appending(path: $0) }, recognizer: VisionReceiptRecognizer(),
                                       sampleRecognizer: FixtureReceiptRecognizer(), structurer: DeterministicReceiptStructurer())
        let task = Task {
            try await pipeline.process(.empty(pages: [page], currency: .usd, date: .now), defaultCurrency: .usd, seed: UUID()) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A missing page file fails clearly instead of producing an empty receipt")
    func missingFile() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ReceiptPipeline(assets: store, fileURL: { directory.appending(path: $0) }, recognizer: VisionReceiptRecognizer(),
                                       sampleRecognizer: FixtureReceiptRecognizer(), structurer: DeterministicReceiptStructurer())
        await #expect(throws: ReceiptAssetError.missingFile) {
            try await pipeline.process(.empty(pages: [ReceiptFixtures.page()], currency: .usd, date: .now), defaultCurrency: .usd, seed: UUID()) { _ in }
        }
    }

    @Test("No recognized text still yields a reviewable manual draft with its pages")
    func noTextFallsBackToManual() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .photos, createdAt: .now)
        let pipeline = ReceiptPipeline(assets: store, fileURL: { directory.appending(path: $0) }, recognizer: SilentRecognizer(),
                                       sampleRecognizer: FixtureReceiptRecognizer(), structurer: DeterministicReceiptStructurer())
        let result = try await pipeline.process(.empty(pages: [page], currency: .usd, date: .now), defaultCurrency: .usd, seed: UUID()) { _ in }
        #expect(result.recognition.status == .failed(.noText))
        #expect(result.pages == [page], "The captured page is kept")
        #expect(result.items.isEmpty)
        #expect(ReceiptValidator.reconcile(result).blockingIssues.map(\.kind).contains(.noItems), "Review asks for the items by hand")
    }

    /// Integration with real Vision OCR on the bundled fictional image. Assertions are semantic
    /// and tolerant (milestone 3 §17.3): no exact confidences, no character-perfect matching.
    @Test("Vision reads the sample receipt well enough to structure it")
    func visionIntegration() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await store.importImage(try sampleData(), id: ReceiptAssetID(), source: .photos, createdAt: DemoScenario.fixedReferenceDate)
        let regions = try await VisionReceiptRecognizer().recognize(page: page, imageURL: directory.appending(path: page.pageFileName), seed: UUID())
        #expect(regions.count >= 20)
        #expect(regions.allSatisfy { (0...1).contains($0.bounds.x) && (0...1).contains($0.bounds.y) })
        let proposal = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: [page], regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate, idSeed: UUID(), timeZone: .gmt
        ))
        #expect(proposal.merchant.value.uppercased().contains("FERNWOOD"))
        #expect(proposal.total.value == Money(104.04))
        #expect(proposal.items.count >= 6)
        #expect(proposal.items.contains { $0.name.value.localizedCaseInsensitiveContains("nachos") && $0.amount == Money(12) })
        #expect(!proposal.items.contains { $0.name.value.contains("4821") })
    }
}

/// A recognizer that finds nothing (blank or unreadable page).
private struct SilentRecognizer: ReceiptRecognizing {
    var kind: RecognitionProviderKind { .onDeviceDeterministic }
    func recognize(page: ReceiptAsset, imageURL: URL, seed: UUID) async throws -> [RecognizedRegion] { [] }
}

private actor StageRecorder {
    private(set) var values: [ReceiptProcessingStage] = []
    func append(_ stage: ReceiptProcessingStage) {
        if values.last != stage { values.append(stage) }
    }
}
