import Foundation

/// Wire format for `POST /v1/receipt-intelligence/parse` (server/API.md, milestone 5 §4–§5).
nonisolated enum ReceiptIntelligenceDTO {
    static let schemaVersion = 1

    // MARK: Request

    nonisolated struct Request: Encodable, Sendable {
        nonisolated struct Consent: Encodable, Sendable {
            let mode: String
            let version: Int
        }

        nonisolated struct Page: Encodable, Sendable {
            let index: Int
            /// JPEG bytes; `JSONEncoder` writes `Data` as base64.
            let image: Data
            let warnings: [String]
        }

        nonisolated struct Region: Encodable, Sendable {
            let id: String
            let page: Int
            let order: Int
            let text: String
            let confidence: Double
            /// x, y, width, height in unit coordinates (top-left origin).
            let box: [Double]
            let alternatives: [String]
        }

        let schemaVersion: Int
        let consent: Consent
        let locale: String?
        let likelyCurrency: String?
        let pages: [Page]
        let regions: [Region]
    }

    // MARK: Response

    nonisolated struct Field<Value: Decodable & Sendable>: Decodable, Sendable {
        let value: Value?
        let attention: String
        let reason: String
        let basis: String
        let regionIds: [String]
    }

    nonisolated struct Item: Decodable, Sendable {
        let name: Field<String>
        let quantity: Int?
        let unitPrice: Int64?
        let lineTotal: Field<Int64>
        let isRefund: Bool
    }

    nonisolated struct Charge: Decodable, Sendable {
        let kind: String
        let label: String
        let amount: Field<Int64>
    }

    nonisolated struct Note: Decodable, Sendable {
        let kind: String
        let chargeKind: String?
    }

    nonisolated struct Warning: Decodable, Sendable {
        let code: String
        let regionIds: [String]
    }

    nonisolated struct Proposal: Decodable, Sendable {
        let merchant: Field<String>
        let date: Field<String>
        let currency: Field<String>
        let items: [Item]
        let charges: [Charge]
        let subtotal: Field<Int64>
        let total: Field<Int64>
        let notes: [Note]
        let warnings: [Warning]
        let overallConfidence: String
    }

    nonisolated struct Issue: Decodable, Sendable {
        let code: String
        let difference: Int64?
    }

    nonisolated struct Validation: Decodable, Sendable {
        let issues: [Issue]
        let reconciled: Bool
    }

    nonisolated struct Response: Decodable, Sendable {
        let schemaVersion: Int
        let provider: String
        let model: String
        let cached: Bool
        let proposal: Proposal
        let validation: Validation
    }
}
