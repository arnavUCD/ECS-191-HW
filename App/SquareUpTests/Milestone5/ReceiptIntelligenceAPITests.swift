import Foundation
@testable import SquareUp
import Testing

@Suite("AI API client")
@MainActor
struct ReceiptIntelligenceAPITests {
    private static let configuration = RemoteConfiguration.make(scheme: "http", host: "127.0.0.1:8080", authMode: "development", firebaseAPIKey: nil)!

    private func api(_ transport: IntelligenceTransport) -> ReceiptIntelligenceAPI {
        let account = AccountSession(configuration: Self.configuration, transport: transport, keychain: KeychainStore(service: "test.\(UUID())"))
        return ReceiptIntelligenceAPI(configuration: Self.configuration, transport: transport, account: account)
    }

    private static let request = ReceiptIntelligenceDTO.Request(
        schemaVersion: 1, consent: .init(mode: "automatic", version: 1), locale: "en_US", likelyCurrency: "USD",
        pages: [.init(index: 0, image: Data([0xFF, 0xD8, 0xFF, 0xD9]), warnings: [])], regions: []
    )

    private nonisolated static func error(_ code: String, retryAfter: Int? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": "x", "requestId": "test"]
        if let retryAfter { error["retryAfterSeconds"] = retryAfter }
        let body: [String: Any] = ["error": error]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    @Test("Posts to the versioned endpoint with the account credential and decodes the proposal")
    func success() async throws {
        let transport = IntelligenceTransport { _, _ in (200, IntelligenceFixtures.dinnerJSON(regionID: { _ in nil })) }
        let response = try await api(transport).parse(Self.request)
        #expect(response.proposal.items.count == 8 && response.schemaVersion == 1)
        let sent = try #require(await transport.requests.first)
        #expect(sent.httpMethod == "POST" && sent.url?.path() == "/v1/receipt-intelligence/parse")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Dev ") == true)
        let body = try #require(sent.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!body.contains("Authorization") && !body.contains("Dev "), "credentials travel only in the header")
    }

    @Test("Every server or network failure maps to an automatic-fallback class", arguments: [
        (503, "ai_unavailable", ReceiptIntelligenceFallback.providerUnavailable),
        (502, "ai_provider_error", .providerUnavailable),
        (502, "ai_invalid_output", .invalidResponse),
        (502, "ai_refused", .refused),
        (504, "ai_timeout", .timedOut),
        (429, "rate_limited", .rateLimited),
        (413, "payload_too_large", .refused),
        (415, "unsupported_media", .refused),
        (403, "ai_consent_required", .refused),
        (401, "credential_expired", .accountUnavailable),
        (503, "temporarily_unavailable", .serverUnreachable),
        (500, "anything", .serverUnreachable),
    ])
    func errorMapping(status: Int, code: String, expected: ReceiptIntelligenceFallback) async {
        let transport = IntelligenceTransport { _, _ in (status, Self.error(code)) }
        await #expect(throws: expected) { try await api(transport).parse(Self.request) }
    }

    @Test("Transport failures: offline, server stopped, and timeout", arguments: [
        (URLError.Code.notConnectedToInternet, ReceiptIntelligenceFallback.offline),
        (.cannotConnectToHost, .serverUnreachable),
        (.timedOut, .timedOut),
        (.cannotFindHost, .serverUnreachable),
    ])
    func transportFailures(code: URLError.Code, expected: ReceiptIntelligenceFallback) async {
        let transport = IntelligenceTransport { _, _ in throw URLError(code) }
        await #expect(throws: expected) { try await api(transport).parse(Self.request) }
    }

    @Test("An unreadable success body is an invalid response")
    func malformedSuccess() async {
        let transport = IntelligenceTransport { _, _ in (200, Data("{\"schemaVersion\":1}".utf8)) }
        await #expect(throws: ReceiptIntelligenceFallback.invalidResponse) { try await api(transport).parse(Self.request) }
    }

    @Test("An identical receipt already in flight is waited for, not sent twice to the provider")
    func inProgressRetries() async throws {
        let transport = IntelligenceTransport { _, attempt in
            attempt == 1 ? (409, Self.error("ai_in_progress", retryAfter: 1)) : (200, IntelligenceFixtures.dinnerJSON(regionID: { _ in nil }))
        }
        let response = try await api(transport).parse(Self.request)
        #expect(response.proposal.items.count == 8)
        #expect(await transport.requests.count == 2)
    }

    @Test("Revoking consent sends a cache deletion")
    func deleteCache() async throws {
        let transport = IntelligenceTransport { _, _ in (200, Data("{\"removed\":1}".utf8)) }
        await api(transport).deleteCachedResults()
        let sent = try #require(await transport.requests.first)
        #expect(sent.httpMethod == "DELETE" && sent.url?.path() == "/v1/receipt-intelligence/cache")
    }

    @Test("Without a configured server there is no AI service")
    func notConfigured() {
        let sharing = SharingService(configuration: nil, local: InMemoryLedgerStore(sample()), directory: SharedRoomDirectory(fileURL: nil))
        #expect(sharing.receiptIntelligence() == nil)
    }
}
