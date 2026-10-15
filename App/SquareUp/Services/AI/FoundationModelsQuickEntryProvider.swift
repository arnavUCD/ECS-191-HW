import Foundation
import FoundationModels

/// On-device quick-entry extraction with Apple Foundation Models.
///
/// The model only *extracts* strings from what the person typed. It never calculates shares,
/// chooses a final payer, or saves anything; `QuickEntryResolver` validates its output and the
/// person confirms every field (CLAUDE.md §6.2: "AI proposes; humans confirm").
nonisolated struct FoundationModelsQuickEntryProvider: QuickEntryProviding {
    let descriptor = AIProviderDescriptor(
        id: "apple.foundation-models.system",
        displayName: String(localized: "Apple Intelligence"),
        location: .onDevice,
        version: ProcessInfo.processInfo.operatingSystemVersionString
    )

    func availability() async -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(String(localized: "This device doesn't support Apple Intelligence."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(String(localized: "Apple Intelligence is turned off in Settings."))
        case .unavailable(.modelNotReady):
            return .unavailable(String(localized: "Apple Intelligence is still getting ready."))
        case .unavailable:
            return .unavailable(String(localized: "Apple Intelligence isn't available right now."))
        }
    }

    func candidate(for text: String, context: QuickEntryContext) async throws -> QuickEntryCandidate {
        let session = LanguageModelSession(instructions: """
        You extract fields from a short note about a shared expense. Copy values exactly as \
        written; never calculate, round, or invent values. If a field is not stated, leave it empty. \
        The person writing is called "me". Known people in this group: \
        \(context.memberNames.joined(separator: ", ")).
        """)
        let response = try await session.respond(to: text, generating: QuickEntryExtraction.self)
        let output = response.content
        return QuickEntryCandidate(
            amountText: output.amount.isEmpty ? nil : output.amount,
            description: output.description.isEmpty ? nil : output.description,
            payerName: output.payer.isEmpty ? nil : output.payer,
            participantNames: output.participants,
            splitsEqually: output.splitsEqually
        )
    }
}

/// Structured output schema. Amounts are strings so no value ever passes through floating point.
@Generable(description: "Fields extracted from a note about a shared expense")
nonisolated struct QuickEntryExtraction {
    @Guide(description: "The total amount exactly as written, digits and an optional decimal point only, e.g. 80 or 42.50. Empty if not stated.")
    var amount: String

    @Guide(description: "A short description of what was bought, e.g. dinner, groceries, Uber. Empty if not stated.")
    var description: String

    @Guide(description: "Who paid. Use \"me\" if the writer paid. Empty if not stated.")
    var payer: String

    @Guide(description: "Everyone sharing the cost, as written. Include \"me\" if the writer shares it.")
    var participants: [String]

    @Guide(description: "True if the cost is split equally or no split method is stated.")
    var splitsEqually: Bool
}
