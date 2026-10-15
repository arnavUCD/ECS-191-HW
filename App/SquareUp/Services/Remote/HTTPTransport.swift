import Foundation

/// The network seam: production uses `URLSession`; tests substitute a scripted transport.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, no URL cache, no credentials persisted by Foundation.
nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Transport failures that mean "we couldn't reach the server" rather than "the server said no".
nonisolated enum TransportFailure {
    static func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func isTimeout(_ error: any Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }
}
