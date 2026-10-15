import Foundation
@testable import SquareUp
import Testing

/// Fixed evaluation set for natural-language quick entry (CLAUDE.md §6.2: "Build a fixed
/// evaluation set"). The same cases can be replayed against any `QuickEntryProviding`.
enum QuickEntryEvaluationSet {
    struct Case: Sendable, CustomTestStringConvertible {
        let text: String
        let amount: String?
        let description: String?
        let payer: String?
        let participants: [String]
        var testDescription: String { text }
    }

    static let cases: [Case] = [
        Case(text: "I paid $80 for dinner and want to split it equally among Alex, Maya, Jordan, and me",
             amount: "80", description: "Dinner", payer: "me", participants: ["Alex", "Maya", "Jordan", "me"]),
        Case(text: "Maya paid 42.50 for groceries with me and Jordan",
             amount: "42.50", description: "Groceries", payer: "maya", participants: ["me", "Jordan"]),
        Case(text: "Uber 18 split with Sam",
             amount: "18", description: "Uber", payer: "me", participants: ["Sam"]),
        Case(text: "I covered $1,240 for the cabin between me, Lena and Sam.",
             amount: "1240", description: "Cabin", payer: "me", participants: ["me", "Lena", "Sam"]),
        Case(text: "Paid 12 bucks for coffee",
             amount: "12", description: "Coffee", payer: "me", participants: []),
    ]
}

@Suite("Rule-based quick entry")
struct RuleBasedQuickEntryTests {
    @Test("Evaluation set", arguments: QuickEntryEvaluationSet.cases)
    func evaluation(testCase: QuickEntryEvaluationSet.Case) {
        let candidate = RuleBasedQuickEntryProvider.parse(testCase.text)
        #expect(candidate.amountText == testCase.amount)
        #expect(candidate.description == testCase.description)
        #expect(candidate.payerName == testCase.payer)
        #expect(candidate.participantNames == testCase.participants)
    }

    @Test("Detects non-equal split requests")
    func nonEqual() {
        #expect(!RuleBasedQuickEntryProvider.parse("I paid 90, 50% for Sam").splitsEqually)
    }
}

@Suite("Quick entry resolver")
struct QuickEntryResolverTests {
    let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
    var tahoeMembers: [Member] { snapshot.members(of: snapshot.group(SampleLedger.GroupKey.tahoe.id)!) }
    let me = SampleLedger.Person.riley.id
    let provider = RuleBasedQuickEntryProvider().descriptor

    @Test("Resolves self references, first names, and unique prefixes")
    func names() {
        #expect(QuickEntryResolver.match("me", members: tahoeMembers, currentUserID: me) == .matched(me))
        #expect(QuickEntryResolver.match("Sam", members: tahoeMembers, currentUserID: me) == .matched(SampleLedger.Person.sam.id))
        #expect(QuickEntryResolver.match("len", members: tahoeMembers, currentUserID: me) == .matched(SampleLedger.Person.lena.id))
        #expect(QuickEntryResolver.match("Alex Rivera", members: tahoeMembers, currentUserID: me) == .matched(SampleLedger.Person.alexRivera.id))
    }

    @Test("Never guesses between two people with the same first name")
    func ambiguous() {
        #expect(QuickEntryResolver.match("Alex", members: tahoeMembers, currentUserID: me) == .ambiguous)
        #expect(QuickEntryResolver.match("Zed", members: tahoeMembers, currentUserID: me) == .unknown)
    }

    @Test("Builds a suggestion with warnings rather than silent guesses")
    func suggestion() {
        let candidate = QuickEntryCandidate(amountText: "84.005", description: "Dinner", payerName: "me",
                                            participantNames: ["Sam", "Alex", "Zed", "me"])
        let result = QuickEntryResolver.resolve(candidate, members: tahoeMembers, currentUserID: me, currency: .usd, provider: provider)
        #expect(result.amount == Money(string: "84.01"))
        #expect(result.participantIDs == [SampleLedger.Person.sam.id, me])
        #expect(result.warnings.contains(.amountPrecision))
        #expect(result.warnings.contains(.ambiguousPerson("Alex")))
        #expect(result.warnings.contains(.unknownPerson("Zed")))
        #expect(result.payerID == me)
    }

    @Test("Missing or invalid amounts are reported, not invented")
    func amounts() {
        let missing = QuickEntryResolver.resolve(QuickEntryCandidate(), members: tahoeMembers, currentUserID: me, currency: .usd, provider: provider)
        #expect(missing.amount == nil)
        #expect(missing.warnings.contains(.amountMissing))
        let invalid = QuickEntryResolver.resolve(QuickEntryCandidate(amountText: "lots"), members: tahoeMembers, currentUserID: me, currency: .usd, provider: provider)
        #expect(invalid.warnings.contains(.amountInvalid("lots")))
        let negative = QuickEntryResolver.resolve(QuickEntryCandidate(amountText: "-5"), members: tahoeMembers, currentUserID: me, currency: .usd, provider: provider)
        #expect(negative.amount == nil)
    }
}

/// Test doubles for the provider boundary.
struct StubProvider: QuickEntryProviding {
    let descriptor: AIProviderDescriptor
    let isAvailable: Bool
    let result: QuickEntryCandidate?

    func availability() async -> AIAvailability { isAvailable ? .available : .unavailable("off") }

    func candidate(for text: String, context: QuickEntryContext) async throws -> QuickEntryCandidate {
        guard let result else { throw StubError.failed }
        return result
    }

    enum StubError: Error { case failed }

    static func onDevice(available: Bool, result: QuickEntryCandidate?) -> StubProvider {
        StubProvider(
            descriptor: AIProviderDescriptor(id: "stub.on-device", displayName: "Stub", location: .onDevice, version: "1"),
            isAvailable: available, result: result
        )
    }
}

@Suite("Quick entry provider selection")
@MainActor
struct QuickEntryServiceTests {
    let snapshot = SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate)
    var members: [Member] { snapshot.members(of: snapshot.group(SampleLedger.GroupKey.apartment.id)!) }
    let me = SampleLedger.Person.riley.id

    private func defaults(allowOnDevice: Bool? = nil) -> UserDefaults {
        let suite = UserDefaults(suiteName: "QuickEntryServiceTests-\(UUID().uuidString)")!
        if let allowOnDevice { suite.set(allowOnDevice, forKey: QuickEntryService.onDevicePreferenceKey) }
        return suite
    }

    @Test("Uses on-device AI when available and allowed")
    func prefersOnDevice() async {
        let service = QuickEntryService(
            onDevice: StubProvider.onDevice(available: true, result: QuickEntryCandidate(amountText: "30", description: "Pizza")),
            defaults: defaults()
        )
        let suggestion = await service.suggest(from: "anything", members: members, currentUserID: me, currency: .usd)
        #expect(suggestion.provider.location == .onDevice)
        #expect(suggestion.amount == Money(30))
        #expect(await service.activeProvider().location == .onDevice)
    }

    @Test("Falls back to rules when the model is unavailable, disabled, or fails")
    func fallsBack() async {
        let text = "I paid $45 for pizza with Maya"
        let unavailable = QuickEntryService(onDevice: StubProvider.onDevice(available: false, result: nil), defaults: defaults())
        let disabled = QuickEntryService(
            onDevice: StubProvider.onDevice(available: true, result: QuickEntryCandidate(amountText: "1")),
            defaults: defaults(allowOnDevice: false)
        )
        let failing = QuickEntryService(onDevice: StubProvider.onDevice(available: true, result: nil), defaults: defaults())
        for service in [unavailable, disabled, failing] {
            let suggestion = await service.suggest(from: text, members: members, currentUserID: me, currency: .usd)
            #expect(suggestion.provider.location == .rules)
            #expect(suggestion.amount == Money(45))
            #expect(suggestion.participantIDs == [SampleLedger.Person.maya.id])
        }
    }
}

@Suite("Category suggestions")
struct CategoryGuesserTests {
    @Test(arguments: [
        ("Dinner at Nopa", ExpenseCategory.food), ("Costco run", .groceries), ("October rent", .housing),
        ("PG&E bill", .utilities), ("Uber to SFO", .transport), ("Cabin rental", .travel),
        ("Concert tickets", .entertainment), ("Poster printing", .supplies), ("Mystery", .other),
        ("BART fare", .transport), ("Groceries", .groceries),
    ])
    func guesses(text: String, expected: ExpenseCategory) {
        #expect(CategoryGuesser.guess(text) == expected)
    }
}
