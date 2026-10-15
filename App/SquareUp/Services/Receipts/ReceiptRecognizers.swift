import Foundation
import Vision

/// Produces recognized text with geometry for one page (milestone 3 §11 `ReceiptRecognizing`).
/// Framework types stay inside implementations; the domain sees `RecognizedRegion` only.
nonisolated protocol ReceiptRecognizing: Sendable {
    var kind: RecognitionProviderKind { get }
    func recognize(page: ReceiptAsset, imageURL: URL, seed: UUID) async throws -> [RecognizedRegion]
}

/// On-device OCR with Vision's `RecognizeTextRequest` (accurate level). Nothing leaves the device.
nonisolated struct VisionReceiptRecognizer: ReceiptRecognizing {
    var kind: RecognitionProviderKind { .onDeviceDeterministic }

    @concurrent
    func recognize(page: ReceiptAsset, imageURL: URL, seed: UUID) async throws -> [RecognizedRegion] {
        guard FileManager.default.fileExists(atPath: imageURL.path) else { throw ReceiptAssetError.missingFile }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: imageURL)
        try Task.checkCancellation()
        return observations.enumerated().compactMap { index, observation in
            let candidates = observation.topCandidates(3)
            guard let best = candidates.first else { return nil }
            let box = observation.boundingBox
            // Vision uses a lower-left origin; the domain uses top-left.
            let bounds = ReceiptRect(x: Double(box.origin.x), y: 1 - Double(box.origin.y) - Double(box.height),
                                     width: Double(box.width), height: Double(box.height))
            return RecognizedRegion(
                id: ReceiptRegionID(DerivedID.make(seed, index + 1)), pageID: page.id, text: best.string,
                confidence: Double(best.confidence), bounds: bounds, alternatives: candidates.dropFirst().map(\.string),
                readingOrder: index
            )
        }
    }
}

/// PROTOTYPE: prerecorded recognition for the bundled fictional sample receipt, so demonstrations
/// and UI tests are deterministic (milestone 3 §17.1 "keep deterministic OCR/structuring fixtures
/// separate from tests that invoke Vision"). It includes one deliberate misreading to correct.
nonisolated struct FixtureReceiptRecognizer: ReceiptRecognizing {
    var kind: RecognitionProviderKind { .fixture }
    let fixtureURL: URL?

    nonisolated struct Fixture: Decodable {
        nonisolated struct Region: Decodable {
            let text: String
            let confidence: Double
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            var alternatives: [String]?
        }

        let regions: [Region]
    }

    init(fixtureURL: URL? = SampleReceipt.recognitionURL) {
        self.fixtureURL = fixtureURL
    }

    func recognize(page: ReceiptAsset, imageURL: URL, seed: UUID) async throws -> [RecognizedRegion] {
        guard let fixtureURL, let data = try? Data(contentsOf: fixtureURL) else { throw RecognitionFailure.recognizerUnavailable }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        return fixture.regions.enumerated().map { index, region in
            RecognizedRegion(
                id: ReceiptRegionID(DerivedID.make(seed, index + 1)), pageID: page.id, text: region.text, confidence: region.confidence,
                bounds: ReceiptRect(x: region.x, y: region.y, width: region.width, height: region.height),
                alternatives: region.alternatives ?? [], readingOrder: index
            )
        }
    }
}

/// The bundled fictional receipt (no real merchant, person, or card).
nonisolated enum SampleReceipt {
    static var imageURL: URL? { Bundle.main.url(forResource: "fernwood-dinner", withExtension: "jpg") }
    static var recognitionURL: URL? { Bundle.main.url(forResource: "fernwood-dinner", withExtension: "json") }
}
