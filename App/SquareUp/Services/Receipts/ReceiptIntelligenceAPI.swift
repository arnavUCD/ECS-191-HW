import Foundation
import OSLog

/// Sends a receipt for AI processing (milestone 5). Tests substitute a scripted implementation.
nonisolated protocol ReceiptIntelligenceServicing: Sendable {
    func parse(_ request: ReceiptIntelligenceDTO.Request) async throws -> ReceiptIntelligenceDTO.Response
    /// Removes this account's cached AI results from the server (consent revoked). Best effort.
    func deleteCachedResults() async
}

/// `POST /v1/receipt-intelligence/parse` with the full-app account (server/API.md).
///
/// Uses its own session: AI processing can take far longer than a room command, so the ordinary
/// 30-second resource timeout would cut it off. Every failure is mapped to a
/// `ReceiptIntelligenceFallback`, which makes the pipeline use the on-device parser.
/// Logs carry the outcome code and duration only — never the request, response, or URL.
nonisolated struct ReceiptIntelligenceAPI: ReceiptIntelligenceServicing {
    let configuration: RemoteConfiguration
    let transport: any HTTPTransport
    let account: AccountSession
    /// How long to wait for an identical receipt already in flight (`409 ai_in_progress`).
    var maximumInProgressWaits = 3

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func parse(_ request: ReceiptIntelligenceDTO.Request) async throws -> ReceiptIntelligenceDTO.Response {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw ReceiptIntelligenceFallback.ineligible
        }
        var waits = 0
        var refreshed = false
        while true {
            let (status, data, envelope) = try await send("POST", path: ["parse"], body: body, forceRefresh: refreshed)
            if (200..<300).contains(status) {
                do {
                    return try JSONDecoder().decode(ReceiptIntelligenceDTO.Response.self, from: data)
                } catch {
                    throw ReceiptIntelligenceFallback.invalidResponse
                }
            }
            if status == 401, envelope?.error.code == "unauthenticated", !refreshed {
                refreshed = true
                continue
            }
            if status == 409, envelope?.error.code == "ai_in_progress", waits < maximumInProgressWaits {
                waits += 1
                try await Task.sleep(for: .seconds(min(5, max(1, envelope?.error.retryAfterSeconds ?? 3))))
                continue
            }
            throw Self.fallback(status: status, code: envelope?.error.code)
        }
    }

    func deleteCachedResults() async {
        _ = try? await send("DELETE", path: ["cache"], body: nil, forceRefresh: false)
    }

    static func fallback(status: Int, code: String?) -> ReceiptIntelligenceFallback {
        switch (status, code) {
        case (503, "ai_unavailable"): .providerUnavailable
        case (502, "ai_provider_error"): .providerUnavailable
        case (502, "ai_invalid_output"): .invalidResponse
        case (502, "ai_refused"): .refused
        case (504, _), (409, "ai_in_progress"): .timedOut
        case (429, "ai_demo_limit"): .demoLimitReached
        case (429, _): .rateLimited
        case (401, _): .accountUnavailable
        case (400..<500, _): .refused
        default: .serverUnreachable
        }
    }

    // MARK: Transport

    private func send(_ method: String, path: [String], body: Data?, forceRefresh: Bool) async throws -> (Int, Data, ErrorEnvelope?) {
        var url = configuration.baseURL
        for component in ["v1", "receipt-intelligence"] + path {
            url.append(path: component, directoryHint: .notDirectory)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            try await request.setValue(account.authorizationHeader(forceRefresh: forceRefresh), forHTTPHeaderField: "Authorization")
        } catch AccountSession.Failure.offline {
            throw ReceiptIntelligenceFallback.offline
        } catch {
            throw ReceiptIntelligenceFallback.accountUnavailable
        }
        let started = ContinuousClock.now
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            let reason = Self.transportFallback(error)
            Log.receipts.notice("AI processing request didn't complete: \(reason.rawValue, privacy: .public)")
            throw reason
        }
        let envelope = (200..<300).contains(response.statusCode) ? nil : try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        Log.receipts.info("""
        AI processing \(method, privacy: .public) \(response.statusCode, privacy: .public) \
        \(envelope?.error.code ?? "-", privacy: .public) in \(started.duration(to: .now), privacy: .public)
        """)
        return (response.statusCode, data, envelope)
    }

    static func transportFallback(_ error: any Error) -> ReceiptIntelligenceFallback {
        guard let code = (error as? URLError)?.code else { return .serverUnreachable }
        switch code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
        default: return .serverUnreachable
        }
    }
}
