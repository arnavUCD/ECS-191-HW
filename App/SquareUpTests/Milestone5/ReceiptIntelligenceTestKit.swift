import Foundation
@testable import SquareUp

/// A scripted AI service: returns a response or throws, records requests, and can wait on a gate.
actor StubIntelligence {
    enum Outcome: Sendable {
        case response(ReceiptIntelligenceDTO.Response)
        case failure(ReceiptIntelligenceFallback)
        case delay(Duration, ReceiptIntelligenceDTO.Response)
    }

    private var outcome: Outcome
    private(set) var requests: [ReceiptIntelligenceDTO.Request] = []
    private(set) var deletions = 0
    let gate: Gate?

    init(_ outcome: Outcome, gate: Gate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func parse(_ request: ReceiptIntelligenceDTO.Request) async throws -> ReceiptIntelligenceDTO.Response {
        requests.append(request)
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        switch outcome {
        case .response(let response): return response
        case .failure(let reason): throw reason
        case .delay(let duration, let response):
            try await Task.sleep(for: duration)
            return response
        }
    }

    func deleteCachedResults() async {
        deletions += 1
    }
}

/// Declared in an extension for the same reason as `ScriptedTransport`'s conformance.
extension StubIntelligence: ReceiptIntelligenceServicing {}

/// Server-shaped responses (fictional) built from the regions the app actually sent.
nonisolated enum IntelligenceFixtures {
    /// The sample dinner's true values (Tiramisu is $8.50; Vision's fixture misreads it as $6.50).
    static func dinnerJSON(regionID: (String) -> String?, schemaVersion: Int = 1, currency: String = "USD", total: Int64 = 10404,
                           tiramisuAttention: String = "check", tiramisuReason: String = "evidenceMismatch") -> Data {
        func f(_ value: Any?, _ text: String? = nil, attention: String = "looksGood", reason: String = "strongEvidence", basis: String = "visible") -> [String: Any] {
            ["value": value ?? NSNull(), "attention": attention, "reason": reason, "basis": basis,
             "regionIds": text.flatMap(regionID).map { [$0] } ?? []]
        }
        func item(_ name: String, _ amount: Int64, _ text: String, quantity: Int? = nil, unit: Int64? = nil,
                  attention: String = "looksGood", reason: String = "strongEvidence") -> [String: Any] {
            ["name": f(name, text), "quantity": quantity ?? NSNull(), "unitPrice": unit ?? NSNull(),
             "lineTotal": f(amount, text, attention: attention, reason: reason), "isRefund": false]
        }
        let proposal: [String: Any] = [
            "merchant": f("Fernwood Supper Club", "FERNWOOD SUPPER CLUB"),
            "date": f("2026-09-24", "09/24/2026 7:42 PM"),
            "currency": f(currency, nil, basis: "layout"),
            "items": [
                item("Truffle Fries", 950, "1 Truffle Fries"),
                item("Margherita Pizza", 1600, "2 Margherita Pizza @ 8.00", quantity: 2, unit: 800),
                item("Caesar Salad", 1125, "1 Caesar Salad"),
                item("Lemonade", 700, "2 Lemonade @ 3.50", quantity: 2, unit: 350),
                item("Mushroom Risotto", 1875, "1 Mushroom Risotto"),
                item("Shared Nachos", 1200, "1 Shared Nachos"),
                item("Tiramisu", 850, "1 Tiramisu", attention: tiramisuAttention, reason: tiramisuReason),
                item("Iced Tea", 325, "1 Iced Tea"),
            ],
            "charges": [
                ["kind": "discount", "label": "Happy Hour Discount", "amount": f(-400, "Happy Hour Discount")],
                ["kind": "tax", "label": "Sales Tax 8.25%", "amount": f(679, "Sales Tax 8.25%")],
                ["kind": "tip", "label": "Tip", "amount": f(1500, "Tip")],
            ],
            "subtotal": f(8625, "SUBTOTAL"),
            "total": f(total, "TOTAL"),
            "notes": [],
            "warnings": [["code": "cardDetailsIgnored", "regionIds": []]],
            "overallConfidence": "high",
        ]
        let body: [String: Any] = [
            "schemaVersion": schemaVersion, "provider": "fake", "model": "fake-model", "cached": false,
            "proposal": proposal, "validation": ["issues": [], "reconciled": true],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    static func dinner(regions: [RecognizedRegion], schemaVersion: Int = 1, currency: String = "USD", total: Int64 = 10404) -> ReceiptIntelligenceDTO.Response {
        decode(dinnerJSON(regionID: { text in regions.first { $0.normalizedText == text }?.id.rawValue.uuidString },
                          schemaVersion: schemaVersion, currency: currency, total: total))
    }

    static func decode<T: Decodable>(_ data: Data) -> T {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(T.self, from: data)
    }
}

/// Requests seen by an `IntelligenceTransport`.
actor RequestLog {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

/// A scripted HTTP transport for the AI API tests: `respond(request, attempt)` gives the status and
/// body (or throws a transport error). Separate from the milestone 4 `ScriptedTransport` so these
/// tests don't change how that type is checked.
nonisolated struct IntelligenceTransport: HTTPTransport {
    let log = RequestLog()
    let respond: @Sendable (URLRequest, Int) async throws -> (Int, Data)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let attempt = await log.append(request)
        let (status, data) = try await respond(request, attempt)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:]) else {
            throw URLError(.badURL)
        }
        return (data, response)
    }

    var requests: [URLRequest] {
        get async { await log.requests }
    }
}
