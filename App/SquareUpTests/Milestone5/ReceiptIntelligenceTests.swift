import CoreGraphics
import Foundation
import ImageIO
@testable import SquareUp
import Testing
import UniformTypeIdentifiers

// Milestone 5: hybrid AI receipt intelligence on the device. No test calls a real server or AI
// provider; the service is scripted (`StubIntelligence`) or the HTTP transport is.

private func temporaryServices() -> ReceiptServices { .temporary() }

private func samplePage(in services: ReceiptServices) async throws -> ReceiptAsset {
    let data = try Data(contentsOf: #require(SampleReceipt.imageURL))
    return try await services.assets.importImage(data, id: ReceiptAssetID(), source: .sample, createdAt: DemoScenario.fixedReferenceDate)
}

/// The sample's prerecorded regions. `pipelineSeed` matches the IDs `ReceiptPipeline` gives page 1.
private func bundledRegions(for page: ReceiptAsset, pipelineSeed: UUID? = nil) async throws -> [RecognizedRegion] {
    let seed = pipelineSeed.map { DerivedID.make($0, 10_000) } ?? ReceiptFixtures.seed
    return try await FixtureReceiptRecognizer().recognize(page: page, imageURL: URL(fileURLWithPath: "/dev/null"), seed: seed)
}

private func input(page: ReceiptAsset, regions: [RecognizedRegion]) -> ReceiptStructuringInput {
    ReceiptStructuringInput(pages: [page], regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate,
                            idSeed: ReceiptFixtures.seed, timeZone: .gmt)
}

private let tinyJPEG: @Sendable (ReceiptAsset) async throws -> Data = { _ in Data([0xFF, 0xD8, 0xFF, 0xD9]) }

@Suite("Processing image")
struct ProcessingImageTests {
    @Test("Sizes stay within Claude's long-edge and visual-token limits, keeping the aspect ratio",
          arguments: [(4032, 3024), (1000, 8000), (3200, 900), (800, 2000), (2576, 1449)])
    func sizeLimits(width: Int, height: Int) {
        let size = ReceiptImageProcessing.processingSize(width: width, height: height)
        #expect(max(size.width, size.height) <= ReceiptImageProcessing.processingMaxLongEdge)
        #expect(ReceiptImageProcessing.visualTokens(width: size.width, height: size.height) <= ReceiptImageProcessing.processingMaxVisualTokens)
        #expect(abs(Double(size.width) / Double(size.height) - Double(width) / Double(height)) < 0.02)
        if ReceiptImageProcessing.visualTokens(width: width, height: height) <= 4784, max(width, height) <= 2576 {
            #expect(size.width == width && size.height == height, "small images are not upscaled or shrunk")
        }
    }

    @Test("The processing JPEG carries no location or camera metadata")
    func metadataRemoved() async throws {
        let services = temporaryServices()
        // An "original" photo with GPS and EXIF, like one from the camera roll.
        let sampleURL = try #require(SampleReceipt.imageURL)
        let original = try #require(CGImageSourceCreateWithURL(sampleURL as CFURL, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.54, kCGImagePropertyGPSLongitude: 121.74],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "fictional camera note"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ExampleCam"],
        ]
        CGImageDestinationAddImageFromSource(destination, original, 0, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let page = try await services.assets.importImage(output as Data, id: ReceiptAssetID(), source: .photos, createdAt: .now)

        let jpeg = try ReceiptImageProcessing.processingJPEG(at: services.fileURL(page.pageFileName))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(read[kCGImagePropertyGPSDictionary] == nil)
        #expect((read[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
        #expect((read[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        let text = try #require(String(bytes: jpeg, encoding: .isoLatin1))
        #expect(!text.contains("fictional camera note") && !text.contains("ExampleCam"))
        let width = try #require(read[kCGImagePropertyPixelWidth] as? Int), height = try #require(read[kCGImagePropertyPixelHeight] as? Int)
        #expect(ReceiptImageProcessing.visualTokens(width: width, height: height) <= 4784 && jpeg.count < ReceiptImageProcessing.processingMaxBytes)
    }
}

@Suite("AI request")
struct IntelligenceRequestTests {
    @Test("OCR evidence is serialized with region IDs, page order, boxes, confidence, and at most two alternatives")
    func regionSerialization() async throws {
        let services = temporaryServices()
        let page = try await samplePage(in: services)
        var regions = try await bundledRegions(for: page)
        let long = RecognizedRegion(id: ReceiptRegionID(), pageID: page.id, text: String(repeating: "A", count: 400), confidence: 1.4,
                                    bounds: ReceiptRect(x: -0.2, y: 0.5, width: 0.3, height: 0.01), alternatives: ["B", "C", "D"], readingOrder: 99)
        regions.append(long)
        var structurer = CloudReceiptStructurer(service: StubIntelligence(.failure(.timedOut)), pageImage: tinyJPEG)
        structurer.localeIdentifier = "en_US@calendar=gregorian"
        let request = try await structurer.makeRequest(input(page: page, regions: regions))
        #expect(request.schemaVersion == 1 && request.consent.mode == "automatic" && request.consent.version == 1)
        #expect(request.locale == "en_US" && request.likelyCurrency == "USD" && request.pages.count == 1 && request.pages[0].index == 0)
        #expect(request.regions.count == regions.count)
        #expect(request.regions[0].id == regions[0].id.rawValue.uuidString && request.regions[0].text == "FERNWOOD SUPPER CLUB")
        let last = try #require(request.regions.last)
        #expect(last.text.count == 300 && last.confidence == 1 && last.box[0] == 0 && last.alternatives == ["B", "C"])
        // The JSON body: images are base64, and nothing about the group, people, or balances is present.
        let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"image\":\"\\/9j\\/") || json.contains("\"image\":\"/9j/"))
        for forbidden in ["Riley", "Maya", "Friday", "payer", "balance", "member", "group", "token", "Authorization"] {
            #expect(!json.contains(forbidden), "\(forbidden) must not be sent")
        }
    }

    @Test("Receipts outside the limits stay on the device")
    func ineligible() async throws {
        let pages = (0..<7).map { _ in ReceiptFixtures.page(ReceiptAssetID()) }
        let structurer = CloudReceiptStructurer(service: StubIntelligence(.failure(.timedOut)), pageImage: tinyJPEG)
        let input = ReceiptStructuringInput(pages: pages, regions: [], defaultCurrency: .usd, captureDate: .now, idSeed: UUID())
        await #expect(throws: ReceiptIntelligenceFallback.ineligible) { try await structurer.makeRequest(input) }
        let failing = CloudReceiptStructurer(service: StubIntelligence(.failure(.timedOut))) { _ in throw ReceiptAssetError.missingFile }
        await #expect(throws: ReceiptIntelligenceFallback.ineligible) { try await failing.makeRequest(ReceiptStructuringInput(
            pages: [pages[0]], regions: [], defaultCurrency: .usd, captureDate: .now, idSeed: UUID()
        )) }
    }

    @Test("Locale identifiers are reduced to what the server accepts")
    func locales() {
        #expect(CloudReceiptStructurer.sanitizedLocale("en_US") == "en_US")
        #expect(CloudReceiptStructurer.sanitizedLocale("zh-Hant_TW@calendar=chinese") == "zh-Hant_TW")
        #expect(CloudReceiptStructurer.sanitizedLocale("@") == nil)
    }
}

@Suite("AI response mapping")
struct IntelligenceMappingTests {
    @Test("A valid response becomes an editable proposal linked to Vision's regions")
    func mapsProposal() async throws {
        let services = temporaryServices()
        let page = try await samplePage(in: services)
        let regions = try await bundledRegions(for: page)
        let proposal = try ReceiptIntelligenceMapper.proposal(from: IntelligenceFixtures.dinner(regions: regions), input: input(page: page, regions: regions))
        #expect(proposal.merchant.value == "Fernwood Supper Club" && proposal.currency.value == .usd)
        #expect(proposal.items.count == 8 && proposal.items.map(\.amount.minorUnits).reduce(0, +) == 8625)
        let tiramisu = try #require(proposal.items.first { $0.name.value == "Tiramisu" })
        #expect(tiramisu.amount == Money(minorUnits: 850, currency: .usd), "the AI read the image's $8.50, not OCR's $6.50")
        #expect(tiramisu.lineTotal.attention == .check && tiramisu.lineTotal.reason == .evidenceMismatch)
        #expect(tiramisu.lineTotal.proposed == tiramisu.amount && tiramisu.proposal?.lineTotal == tiramisu.amount, "the proposal is kept for audit")
        let fries = try #require(proposal.items.first)
        let friesRegion = try #require(regions.first { $0.text == "1 Truffle Fries" })
        #expect(fries.lineTotal.sourceRegionIDs == [friesRegion.id])
        #expect(proposal.items[1].quantity == 2 && proposal.items[1].unitPrice == Money(minorUnits: 800, currency: .usd))
        #expect(proposal.charges.map(\.kind) == [.discount, .tax, .tip] && proposal.charges[0].value.minorUnits == -400)
        #expect(proposal.total.value == Money(minorUnits: 10404, currency: .usd))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        #expect(calendar.dateComponents([.year, .month, .day], from: proposal.date.value) == DateComponents(year: 2026, month: 9, day: 24))
        // Deterministic validation on device agrees: the receipt reconciles exactly.
        var draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
        draft.regions = regions
        draft = proposal.applied(to: draft)
        #expect(ReceiptValidator.reconcile(draft).isReconciled)
    }

    @Test("Region references the app didn't send are dropped")
    func unknownRegions() throws {
        let page = ReceiptFixtures.page()
        let regions = ReceiptFixtures.regions(ReceiptFixtures.dinner)
        let response = IntelligenceFixtures.dinner(regions: []) // no regions resolved → empty references
        let stranger: ReceiptIntelligenceDTO.Response = IntelligenceFixtures.decode(IntelligenceFixtures.dinnerJSON(regionID: { _ in UUID().uuidString }))
        let fromStranger = try ReceiptIntelligenceMapper.proposal(from: stranger, input: input(page: page, regions: regions))
        #expect(fromStranger.items.allSatisfy { $0.sourceRegionIDs.isEmpty })
        #expect(try ReceiptIntelligenceMapper.proposal(from: response, input: input(page: page, regions: regions)).items.count == 8)
    }

    @Test("Anything outside the contract rejects the whole response", arguments: [
        #"{"schemaVersion": 2}"#, #""currency": "usd""#, #""currency": "DOLLARS""#, #""attention": "fine""#,
        #""kind": "gratuity""#, #""lineTotal": {"value": 999999999999999"#,
    ])
    func rejectsOutOfContract(mutation: String) throws {
        let regions = ReceiptFixtures.regions(ReceiptFixtures.dinner)
        var json = try #require(String(bytes: IntelligenceFixtures.dinnerJSON(regionID: { _ in nil }), encoding: .utf8))
        switch mutation {
        case #"{"schemaVersion": 2}"#: json = json.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
        case #""currency": "usd""#: json = json.replacingOccurrences(of: #""value":"USD""#, with: #""value":"usd""#)
        case #""currency": "DOLLARS""#: json = json.replacingOccurrences(of: #""value":"USD""#, with: #""value":"DOLLARS""#)
        case #""attention": "fine""#: json = json.replacingOccurrences(of: #""attention":"check""#, with: #""attention":"fine""#)
        case #""kind": "gratuity""#: json = json.replacingOccurrences(of: #""kind":"tip""#, with: #""kind":"gratuity""#)
        default: json = json.replacingOccurrences(of: #""value":950"#, with: #""value":999999999999999"#)
        }
        let response: ReceiptIntelligenceDTO.Response = IntelligenceFixtures.decode(Data(json.utf8))
        #expect(throws: ReceiptIntelligenceFallback.invalidResponse) {
            try ReceiptIntelligenceMapper.proposal(from: response, input: input(page: ReceiptFixtures.page(), regions: regions))
        }
    }

    @Test("Sign problems are checked once by the validator; person-only reasons never come from the server")
    func attentionNormalization() throws {
        let data = IntelligenceFixtures.dinnerJSON(regionID: { _ in nil }, tiramisuAttention: "needsResolution", tiramisuReason: "invalidValue")
        var json = try #require(String(bytes: data, encoding: .utf8))
        json = json.replacingOccurrences(of: #""reason":"strongEvidence""#, with: #""reason":"confirmedByPerson""#)
        let response: ReceiptIntelligenceDTO.Response = IntelligenceFixtures.decode(Data(json.utf8))
        let proposal = try ReceiptIntelligenceMapper.proposal(from: response, input: input(page: ReceiptFixtures.page(), regions: []))
        let tiramisu = try #require(proposal.items.first { $0.name.value == "Tiramisu" })
        #expect(tiramisu.lineTotal.attention == .check)
        #expect(proposal.items.allSatisfy { $0.name.reason != .confirmedByPerson && !$0.name.isEdited })
    }
}

@Suite("AI pipeline and automatic fallback")
struct IntelligencePipelineTests {
    private func run(_ route: (ReceiptServices, [RecognizedRegion]) -> ReceiptStructuringRoute) async throws -> ReceiptDraft {
        let services = temporaryServices()
        let page = try await samplePage(in: services)
        let regions = try await bundledRegions(for: page, pipelineSeed: ReceiptFixtures.seed)
        let draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
        return try await services.pipeline.process(draft, defaultCurrency: .usd, seed: ReceiptFixtures.seed, route: route(services, regions)) { _ in }
    }

    @Test("With consent and a server, Claude structures the receipt and Vision's evidence is kept")
    func cloudPath() async throws {
        let result = try await run { services, regions in
            .cloud(CloudReceiptStructurer(service: StubIntelligence(.response(IntelligenceFixtures.dinner(regions: regions))), fileURL: services.fileURL))
        }
        #expect(result.recognition.provider == .cloudModel && result.recognition.fallback == nil)
        #expect(result.recognition.cloud?.schemaVersion == 1 && result.recognition.cloud?.cached == false)
        #expect(result.regions.count == 40, "Vision's regions are always produced and stored")
        #expect(result.items.first { $0.name.value == "Tiramisu" }?.amount.minorUnits == 850)
        #expect(result.recognition.status == .completed)
    }

    @Test("Every failure class falls back to the on-device parser with a complete, editable draft",
          arguments: ReceiptIntelligenceFallback.allCases)
    func fallback(reason: ReceiptIntelligenceFallback) async throws {
        let result = try await run { _, _ in .cloud(CloudReceiptStructurer(service: StubIntelligence(.failure(reason)), pageImage: tinyJPEG)) }
        #expect(result.recognition.fallback == reason && result.recognition.cloud == nil)
        #expect(result.recognition.provider == .fixture && result.recognition.status == .completed)
        #expect(result.items.count == 8 && result.total.value != nil, "the deterministic parser still prepared everything")
    }

    @Test("A malformed response and a slow server both fall back")
    func malformedAndSlow() async throws {
        let wrongSchema = try await run { _, regions in
            .cloud(CloudReceiptStructurer(service: StubIntelligence(.response(IntelligenceFixtures.dinner(regions: regions, schemaVersion: 3))),
                                          pageImage: tinyJPEG))
        }
        #expect(wrongSchema.recognition.fallback == .invalidResponse && wrongSchema.items.count == 8)
        let slow = try await run { _, regions in
            var structurer = CloudReceiptStructurer(service: StubIntelligence(.delay(.seconds(30), IntelligenceFixtures.dinner(regions: regions))),
                                                    pageImage: tinyJPEG)
            structurer.deadline = .milliseconds(200)
            return .cloud(structurer)
        }
        #expect(slow.recognition.fallback == .timedOut && slow.recognition.provider == .fixture)
    }

    @Test("On-device-only processing never calls the service and shows no notice")
    func onDeviceOnly() async throws {
        let result = try await run { _, _ in .onDevice(.onDeviceOnly) }
        #expect(result.recognition.fallback == .onDeviceOnly && result.recognition.fallback?.showsNotice == false)
        let noServer = try await run { _, _ in .onDevice(nil) }
        #expect(noServer.recognition.fallback == nil, "builds without a server behave exactly as in milestone 3")
    }

    @Test("Cancelling during AI processing stops the pipeline")
    func cancellation() async throws {
        let services = temporaryServices()
        let page = try await samplePage(in: services)
        let gate = Gate()
        let stub = StubIntelligence(.failure(.timedOut), gate: gate)
        let task = Task {
            try await services.pipeline.process(.empty(pages: [page], currency: .usd, date: .now), defaultCurrency: .usd, seed: UUID(),
                                                route: .cloud(CloudReceiptStructurer(service: stub, pageImage: tinyJPEG))) { _ in }
        }
        while await stub.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Evidence highlighting uses the regions Claude cited")
    @MainActor
    func evidenceHighlighting() async throws {
        let result = try await run { services, regions in
            .cloud(CloudReceiptStructurer(service: StubIntelligence(.response(IntelligenceFixtures.dinner(regions: regions))), fileURL: services.fileURL))
        }
        var harness = RoomHarness()
        try harness.run(.createDraft(harness.roomID, groupID: harness.group, pages: result.pages, currency: .usd))
        try harness.run(.saveDraft(harness.roomID, expectedRevision: harness.revision, receipt: result, groupID: harness.group, payerID: harness.host))
        let review = ReceiptReviewModel(room: harness.room, snapshot: harness.engine.state, now: DemoScenario.fixedReferenceDate)
        let tiramisu = try #require(result.items.first { $0.name.value == "Tiramisu" })
        review.show(.item(tiramisu.id))
        let expected = try #require(result.regions.first { $0.text == "1 Tiramisu" })
        #expect(Set(review.highlights(on: result.pages[0])) == [expected.bounds])
    }

    @Test("Drafts saved before milestone 5 still decode")
    func backwardCompatibleDecoding() throws {
        var info = RecognitionInfo()
        info.status = .completed
        let encoded = try JSONEncoder().encode(info)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fallback")
        object.removeValue(forKey: "cloud")
        let decoded = try JSONDecoder().decode(RecognitionInfo.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.fallback == nil && decoded.cloud == nil && decoded.status == .completed)
    }
}

@Suite("Deterministic validation of AI values")
struct IntelligenceValidationTests {
    @Test("An unread amount blocks until the person resolves it")
    func needsResolutionBlocks() {
        var draft = ReceiptFixtures.draft(ReceiptFixtures.dinner)
        #expect(!ReceiptValidator.reconcile(draft).blockingIssues.contains { if case .itemNeedsResolution = $0.kind { true } else { false } })
        draft.items[0].lineTotal = ReceiptField(.zero(.usd), attention: .needsResolution, reason: .notFound)
        let blocked = ReceiptValidator.reconcile(draft)
        #expect(blocked.blockingIssues.contains { $0.kind == .itemNeedsResolution(draft.items[0].id) })
        draft.items[0].lineTotal.edit(Money(minorUnits: 950, currency: .usd), by: People.riley, at: .now)
        #expect(!ReceiptValidator.reconcile(draft).blockingIssues.contains { $0.kind == .itemNeedsResolution(draft.items[0].id) })
    }

    @Test("A total that wasn't printed must be confirmed, even when it reconciles")
    func derivedTotalNeedsConfirmation() {
        var draft = ReceiptFixtures.draft(ReceiptFixtures.dinner)
        let total = draft.total.value
        draft.total = ReceiptField(total, attention: .needsResolution, reason: .derived)
        #expect(ReceiptValidator.reconcile(draft).blockingIssues.map(\.kind) == [.totalNeedsConfirmation])
        draft.total.edit(total, by: People.riley, at: .now)
        #expect(ReceiptValidator.reconcile(draft).canConfirm)
    }

    @Test("Receipts built from server data (shared rooms) are not caught by the AI-only rules")
    func sharedRoomReceiptsUnaffected() {
        // RemoteRoomMapper and the parity runner start from `.empty` (total "needs resolution, not
        // found") and assign the value directly; that must stay confirmable, as in milestone 4.
        var draft = ReceiptDraft.empty(pages: [], currency: .usd, date: DemoScenario.fixedReferenceDate)
        draft.merchant.value = "Fictional Diner"
        draft.total.value = Money(minorUnits: 950, currency: .usd)
        draft.items = [ReceiptLineItem(name: ReceiptField("Fries"), lineTotal: ReceiptField(Money(minorUnits: 950, currency: .usd)))]
        #expect(ReceiptValidator.reconcile(draft).canConfirm)
    }

    @Test("A charge marked needs-resolution blocks until edited")
    func chargeNeedsResolution() {
        var draft = ReceiptFixtures.draft(ReceiptFixtures.dinner)
        draft.charges[0].amount = ReceiptField(draft.charges[0].value, attention: .needsResolution, reason: .notFound)
        #expect(ReceiptValidator.reconcile(draft).blockingIssues.contains { $0.kind == .chargeNeedsResolution(draft.charges[0].id) })
    }
}

@Suite("AI consent")
@MainActor
struct IntelligenceConsentTests {
    private func defaults() -> UserDefaults {
        let name = "test.receiptAI.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("The choice persists, is reversible, and agreeing to an older disclosure asks again")
    func persistence() {
        let store = defaults()
        let settings = ReceiptAISettings(defaults: store)
        #expect(settings.mode == .undecided)
        settings.choose(.automatic)
        #expect(ReceiptAISettings(defaults: store).mode == .automatic)
        settings.choose(.onDeviceOnly)
        #expect(ReceiptAISettings(defaults: store).mode == .onDeviceOnly)
        store.set("automatic.v0", forKey: ReceiptAISettings.storageKey)
        #expect(ReceiptAISettings(defaults: store).mode == .undecided)
        #expect(ReceiptAISettings(defaults: nil, initial: .automatic).mode == .automatic)
    }

    @Test("Turning AI off deletes the account's cached results on the server")
    func revocation() async {
        let stub = StubIntelligence(.failure(.timedOut))
        let environment = AppEnvironment(ledger: InMemoryLedgerStore(sample()), receiptAI: ReceiptAISettings(defaults: nil, initial: .automatic),
                                         receiptIntelligence: stub)
        await environment.setReceiptAIMode(.onDeviceOnly)
        let deletions = await stub.deletions
        #expect(environment.receiptAI.mode == .onDeviceOnly && deletions == 1)
        await environment.setReceiptAIMode(.onDeviceOnly)
        #expect(await stub.deletions == 1, "only when consent is actually withdrawn")
    }
}

@Suite("Receipt flow with AI")
@MainActor
struct IntelligenceFlowTests {
    private struct Flow {
        let model: ReceiptFlowModel
        let stub: StubIntelligence
        let environment: AppEnvironment
    }

    private func flow(mode: ReceiptAIMode, outcome: StubIntelligence.Outcome? = nil, connectivity: ConnectivityMonitor.Status = .online,
                      configured: Bool = true, gate: Gate? = nil) async throws -> (Flow, ReceiptAsset) {
        let services = ReceiptServices.temporary()
        let page = try await samplePage(in: services)
        // Region references don't need to resolve here (the pipeline seeds IDs from the new room's ID).
        let regions = try await bundledRegions(for: page)
        let stub = StubIntelligence(outcome ?? .response(IntelligenceFixtures.dinner(regions: regions)), gate: gate)
        let environment = AppEnvironment(
            ledger: InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate }),
            connectivity: ConnectivityMonitor(forcedStatus: connectivity), receipts: services,
            configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate,
            receiptAI: ReceiptAISettings(defaults: nil, initial: mode), receiptIntelligence: configured ? stub : nil
        )
        let model = ReceiptFlowModel(environment: environment, request: ReceiptFlowRequest(start: .new(groupID: Groups.friday)))
        await model.load()
        return (Flow(model: model, stub: stub, environment: environment), page)
    }

    private func waitUntilDone(_ model: ReceiptFlowModel) async throws {
        var waited = 0
        while model.isProcessing || model.room?.receipt.recognition.status == .inProgress, waited < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        await model.load()
    }

    @Test("The first eligible receipt asks first; agreeing processes it with AI")
    func consentThenCloud() async throws {
        let (flow, page) = try await flow(mode: .undecided)
        await flow.model.start(with: [page])
        #expect(flow.model.isAskingForAIConsent && flow.model.step == .processing)
        #expect(await flow.stub.requests.isEmpty, "nothing is sent before the person chooses")
        flow.model.resolveAIConsent(.automatic)
        try await waitUntilDone(flow.model)
        #expect(flow.environment.receiptAI.mode == .automatic)
        #expect(await flow.stub.requests.count == 1)
        let recognition = try #require(flow.model.room?.receipt.recognition)
        #expect(recognition.provider == .cloudModel && recognition.fallback == nil)
        #expect(flow.model.step == .review)
    }

    @Test("Dismissing the disclosure keeps this receipt on the device and asks again next time")
    func dismissedConsent() async throws {
        let (flow, page) = try await flow(mode: .undecided)
        await flow.model.start(with: [page])
        flow.model.resolveAIConsent(nil)
        try await waitUntilDone(flow.model)
        #expect(flow.environment.receiptAI.mode == .undecided)
        #expect(await flow.stub.requests.isEmpty)
        let recognition = try #require(flow.model.room?.receipt.recognition)
        #expect(recognition.fallback == .notConsented && recognition.fallback?.showsNotice == false && recognition.provider == .fixture)
    }

    @Test("On-device only never asks and never sends")
    func onDeviceOnly() async throws {
        let (flow, page) = try await flow(mode: .onDeviceOnly)
        await flow.model.start(with: [page])
        #expect(!flow.model.isAskingForAIConsent)
        try await waitUntilDone(flow.model)
        #expect(await flow.stub.requests.isEmpty)
        #expect(flow.model.room?.receipt.recognition.fallback == .onDeviceOnly && flow.model.room?.receipt.items.count == 8)
    }

    @Test("Offline: the on-device parser runs immediately, without trying the network")
    func offline() async throws {
        let (flow, page) = try await flow(mode: .automatic, connectivity: .offline)
        await flow.model.start(with: [page])
        try await waitUntilDone(flow.model)
        #expect(await flow.stub.requests.isEmpty)
        #expect(flow.model.room?.receipt.recognition.fallback == .offline)
        #expect(flow.model.announcements.last?.contains(ReceiptLanguage.preparedOnDevice) == true)
    }

    @Test("Server stopped: automatic fallback with the calm notice")
    func serverStopped() async throws {
        let (flow, page) = try await flow(mode: .automatic, outcome: .failure(.serverUnreachable))
        await flow.model.start(with: [page])
        try await waitUntilDone(flow.model)
        let receipt = try #require(flow.model.room?.receipt)
        #expect(receipt.recognition.fallback == .serverUnreachable && receipt.recognition.fallback?.showsNotice == true)
        #expect(receipt.items.count == 8 && flow.model.step == .review)
    }

    @Test("Builds without a server never show the disclosure (milestone 3 behaviour)")
    func notConfigured() async throws {
        let (flow, page) = try await flow(mode: .undecided, configured: false)
        await flow.model.start(with: [page])
        #expect(!flow.model.isAskingForAIConsent)
        try await waitUntilDone(flow.model)
        #expect(flow.model.room?.receipt.recognition.fallback == nil && flow.model.room?.receipt.recognition.provider == .fixture)
    }

    @Test("VoiceOver hears each stage and the result")
    func announcements() async throws {
        let (flow, page) = try await flow(mode: .automatic, outcome: .failure(.timedOut))
        await flow.model.start(with: [page])
        try await waitUntilDone(flow.model)
        let spoken = flow.model.announcements
        for stage in ReceiptProcessingStage.allCases.dropLast() {
            #expect(spoken.contains(stage.title), "\(stage.title)")
        }
        #expect(spoken.last?.hasPrefix(String(localized: "Receipt ready to review.")) == true)
    }

    @Test("Stopping during AI processing keeps the draft and its pages")
    func cancelKeepsDraft() async throws {
        let gate = Gate()
        let (flow, page) = try await flow(mode: .automatic, outcome: .failure(.timedOut), gate: gate)
        await flow.model.start(with: [page])
        while await flow.stub.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        flow.model.cancelRecognition()
        await gate.open()
        try await waitUntilDone(flow.model)
        let receipt = try #require(flow.model.room?.receipt)
        #expect(receipt.recognition.status == .skipped && receipt.pages == [page] && flow.model.step == .review)
    }
}
