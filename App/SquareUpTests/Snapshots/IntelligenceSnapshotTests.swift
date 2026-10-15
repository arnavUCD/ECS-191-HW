import Foundation
import SnapshotTesting
@testable import SquareUp
import SwiftUI
import Testing
import UIKit

/// Milestone 5 visual regression: the AI disclosure, review after AI processing and after the
/// on-device fallback, and the Profile choice — light, dark, narrow, and an accessibility size.
@Suite("Snapshots · M5 receipt intelligence", .serialized)
@MainActor
struct IntelligenceSnapshotTests {
    private static let services = ReceiptServices.temporary()

    private func assertScreen<V: View>(
        _ view: V, named name: String, size: CGSize = SnapshotHost.phone, style: UIUserInterfaceStyle = .dark,
        fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) async {
        let image = await SnapshotHost.render(view, size: size, style: style, settle: .milliseconds(1800))
        assertSnapshot(of: image, as: .image(precision: 0.99), named: name, fileID: fileID, file: file, testName: testName, line: line, column: column)
    }

    private func samplePage() async throws -> ReceiptAsset {
        let data = try Data(contentsOf: #require(SampleReceipt.imageURL))
        return try await Self.services.assets.importImage(
            data, id: ReceiptAssetID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-0000000005AA")!), source: .sample,
            createdAt: DemoScenario.fixedReferenceDate
        )
    }

    /// A review screen for a draft prepared by `prepare` (cloud or on-device).
    private func review(_ prepare: (ReceiptAsset, [RecognizedRegion]) throws -> ReceiptDraft) async throws -> some View {
        let page = try await samplePage()
        let regions = try await FixtureReceiptRecognizer().recognize(page: page, imageURL: Self.services.fileURL(page.pageFileName),
                                                                     seed: ReceiptFixtures.seed)
        var harness = RoomHarness()
        try harness.run(.createDraft(harness.roomID, groupID: Groups.friday, pages: [page], currency: .usd))
        try harness.run(.saveDraft(harness.roomID, expectedRevision: harness.revision, receipt: try prepare(page, regions), groupID: Groups.friday,
                                   payerID: People.riley))
        let environment = AppEnvironment(
            ledger: InMemoryLedgerStore(harness.engine.state, now: { DemoScenario.fixedReferenceDate }),
            connectivity: ConnectivityMonitor(forcedStatus: .online), receipts: Self.services,
            configuration: LaunchConfiguration(isUITesting: true), fixedNow: DemoScenario.fixedReferenceDate
        )
        return ReceiptFlowView(request: ReceiptFlowRequest(start: .resume(harness.roomID)))
            .environment(environment).environment(AppRouter()).squareUpTheme()
    }

    private func onDeviceDraft(page: ReceiptAsset, regions: [RecognizedRegion], fallback: ReceiptIntelligenceFallback) -> ReceiptDraft {
        var draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
        draft.regions = regions
        draft = DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: [page], regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate, idSeed: ReceiptFixtures.seed,
            timeZone: .gmt
        )).applied(to: draft)
        draft.recognition.status = .completed
        draft.recognition.provider = .fixture
        draft.recognition.fallback = fallback
        return draft
    }

    @Test func aiConsent() async {
        let sheet = ReceiptAIConsentSheet { _ in }.environment(AppEnvironment.preview()).squareUpTheme()
        await assertScreen(sheet, named: "dark")
        await assertScreen(sheet, named: "narrow", size: SnapshotHost.compactPhone)
        await assertScreen(sheet.dynamicTypeSize(.accessibility2), named: "ax2", size: CGSize(width: 402, height: 1500))
    }

    @Test func reviewPreparedOnDevice() async throws {
        let view = try await review { page, regions in onDeviceDraft(page: page, regions: regions, fallback: .serverUnreachable) }
        await assertScreen(view, named: "dark")
    }

    @Test func reviewAfterAIProcessing() async throws {
        let view = try await review { page, regions in
            let input = ReceiptStructuringInput(pages: [page], regions: regions, defaultCurrency: .usd, captureDate: DemoScenario.fixedReferenceDate,
                                                idSeed: ReceiptFixtures.seed, timeZone: .gmt)
            var draft = ReceiptDraft.empty(pages: [page], currency: .usd, date: DemoScenario.fixedReferenceDate)
            draft.regions = regions
            draft = try ReceiptIntelligenceMapper.proposal(from: IntelligenceFixtures.dinner(regions: regions), input: input).applied(to: draft)
            draft.recognition.status = .completed
            draft.recognition.provider = .cloudModel
            draft.recognition.cloud = CloudProcessingInfo(schemaVersion: 1, cached: false, durationMilliseconds: 4200, overallConfidence: .looksGood)
            return draft
        }
        await assertScreen(view, named: "dark")
    }

    @Test func profileReceiptProcessing() async {
        // A fixed on-device answer: the simulator's Apple Intelligence readiness changes between runs.
        let quickEntry = QuickEntryService(onDevice: StubProvider.onDevice(available: true, result: nil),
                                           defaults: UserDefaults(suiteName: "IntelligenceSnapshotTests")!)
        let environment = AppEnvironment(
            ledger: InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate }),
            connectivity: ConnectivityMonitor(forcedStatus: .online), quickEntry: quickEntry,
            configuration: LaunchConfiguration(isUITesting: true),
            fixedNow: DemoScenario.fixedReferenceDate, receiptAI: ReceiptAISettings(defaults: nil, initial: .automatic),
            receiptIntelligence: StubIntelligence(.failure(.timedOut))
        )
        let view = NavigationStack { ProfileView() }.environment(environment).environment(AppRouter()).squareUpTheme()
        await assertScreen(view, named: "dark", size: CGSize(width: 402, height: 2600))
    }
}
