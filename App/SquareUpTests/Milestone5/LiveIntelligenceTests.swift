import Foundation
@testable import SquareUp
import Testing

/// The real network stack (URLSession, account header, JSON) against a running server.
///
/// Opt-in like `LiveServerTests`: `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8080` with a local
/// server started as
/// `SQUAREUP_ALLOW_DEV_AUTH=1 SQUAREUP_AI_PROVIDER=recorded SQUAREUP_AI_RECORDED_DIR=dev/recorded .venv/bin/python main.py`
/// (a recorded fictional answer for the bundled sample; no API key, no provider call).
@Suite("Live AI server", .enabled(if: LiveServer.configuration != nil), .serialized)
struct LiveIntelligenceTests {
    private func api() throws -> ReceiptIntelligenceAPI {
        let configuration = try #require(LiveServer.configuration)
        let transport = URLSessionTransport(session: ReceiptIntelligenceAPI.makeSession())
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "live.ai.\(UUID())"))
        return ReceiptIntelligenceAPI(configuration: configuration, transport: transport, account: account)
    }

    @Test("The sample receipt is structured by the server, linked to Vision's regions, and cached on repeat")
    func sampleThroughServer() async throws {
        let services = ReceiptServices.temporary()
        let data = try Data(contentsOf: #require(SampleReceipt.imageURL))
        let page = try await services.assets.importImage(data, id: ReceiptAssetID(), source: .sample, createdAt: .now)
        let service = try api()
        func run() async throws -> ReceiptDraft {
            try await services.pipeline.process(.empty(pages: [page], currency: .usd, date: .now), defaultCurrency: .usd, seed: ReceiptFixtures.seed,
                                                route: .cloud(CloudReceiptStructurer(service: service, fileURL: services.fileURL))) { _ in }
        }
        let first = try await run()
        #expect(first.recognition.provider == .cloudModel && first.recognition.fallback == nil)
        let tiramisu = try #require(first.items.first { $0.name.value == "Tiramisu" })
        #expect(tiramisu.amount.minorUnits == 850 && tiramisu.lineTotal.reason == .evidenceMismatch && !tiramisu.sourceRegionIDs.isEmpty)
        #expect(ReceiptValidator.reconcile(first).isReconciled)
        let second = try await run()
        #expect(second.recognition.cloud?.cached == true, "the unchanged receipt is not processed (or charged) twice")
        await service.deleteCachedResults()
    }
}

@Suite("AI fallback over the real network stack")
struct ServerStoppedTests {
    @Test("With the server stopped, the receipt is prepared on the device")
    func serverStopped() async throws {
        // Nothing listens on port 1: the connection is refused immediately, like a stopped server.
        let configuration = try #require(RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:1", authMode: "development", firebaseAPIKey: nil))
        let transport = URLSessionTransport(session: ReceiptIntelligenceAPI.makeSession())
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.stopped.\(UUID())"))
        let service = ReceiptIntelligenceAPI(configuration: configuration, transport: transport, account: account)
        let services = ReceiptServices.temporary()
        let data = try Data(contentsOf: #require(SampleReceipt.imageURL))
        let page = try await services.assets.importImage(data, id: ReceiptAssetID(), source: .sample, createdAt: .now)
        let result = try await services.pipeline.process(
            .empty(pages: [page], currency: .usd, date: .now), defaultCurrency: .usd, seed: UUID(),
            route: .cloud(CloudReceiptStructurer(service: service, fileURL: services.fileURL))
        ) { _ in }
        #expect(result.recognition.fallback == .serverUnreachable && result.recognition.fallback?.showsNotice == true)
        #expect(result.recognition.provider == .fixture && result.items.count == 8 && result.recognition.status == .completed)
    }
}
