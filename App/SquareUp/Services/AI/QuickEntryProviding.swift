import Foundation

/// Where AI processing happens. Shown to people when it affects privacy.
nonisolated enum AIProcessingLocation: String, Sendable, Equatable {
    /// Apple Foundation Models on this device. Nothing leaves the iPhone.
    case onDevice
    /// Apple Private Cloud Compute. Requires eligibility + entitlement review (not enabled).
    case privateCloud
    /// Square Up's server-side pipeline (OpenAI Responses API behind the Flask server).
    /// Credentials live only on the server. Not available until the server milestone.
    case server
    /// Deterministic rules. No model involved.
    case rules

    var disclosure: String {
        switch self {
        case .onDevice: String(localized: "Processed on this iPhone with Apple Intelligence")
        case .privateCloud: String(localized: "Processed with Apple Private Cloud Compute")
        case .server: String(localized: "Processed by Square Up's server")
        case .rules: String(localized: "Processed on this iPhone without AI")
        }
    }
}

/// Metadata recorded with each suggestion for evaluation. Contains no personal content.
nonisolated struct AIProviderDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let location: AIProcessingLocation
    let version: String
}

nonisolated enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
}

/// Context a provider may use. Names only — no balances or private settings
/// (overview: "Avoid using private financial information for unrelated AI features").
nonisolated struct QuickEntryContext: Equatable, Sendable {
    let memberNames: [String]
    let currentUserName: String
    let currency: CurrencyCode
}

/// Raw, *untrusted* provider output. Everything is a string; `QuickEntryResolver` validates it
/// deterministically before anything reaches the expense form.
nonisolated struct QuickEntryCandidate: Equatable, Sendable {
    var amountText: String?
    var description: String?
    var payerName: String?
    var participantNames: [String]
    var splitsEqually: Bool

    init(amountText: String? = nil, description: String? = nil, payerName: String? = nil,
         participantNames: [String] = [], splitsEqually: Bool = true) {
        self.amountText = amountText
        self.description = description
        self.payerName = payerName
        self.participantNames = participantNames
        self.splitsEqually = splitsEqually
    }
}

/// The replaceable AI boundary for natural-language quick entry.
///
/// Implementations: `FoundationModelsQuickEntryProvider` (on-device) and
/// `RuleBasedQuickEntryProvider` (deterministic fallback). A server-backed provider will
/// conform to the same protocol when the Flask/OpenAI pipeline exists.
nonisolated protocol QuickEntryProviding: Sendable {
    var descriptor: AIProviderDescriptor { get }
    func availability() async -> AIAvailability
    func candidate(for text: String, context: QuickEntryContext) async throws -> QuickEntryCandidate
}
