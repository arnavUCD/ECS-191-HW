import Foundation
@testable import SquareUp
import Testing

private func usd(_ text: String) -> Money { Money(string: text)! }
private let reference = DemoScenario.fixedReferenceDate

@Suite("Seeded sample ledger")
struct SampleLedgerTests {
    @Test("Every seeded expense satisfies every invariant", arguments: DemoScenario.allCases)
    func invariants(scenario: DemoScenario) throws {
        guard let snapshot = scenario.snapshot(referenceDate: reference) else { return }
        for expense in snapshot.expenses {
            let group = try #require(snapshot.group(expense.groupID))
            try ExpenseValidator.validate(expense, in: group)
        }
    }

    @Test("The sample is deterministic")
    func deterministic() {
        #expect(SampleLedger.make(referenceDate: reference) == SampleLedger.make(referenceDate: reference))
    }

    @Test("Large amounts scale every figure exactly")
    func largeAmounts() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(
            referenceDate: reference, options: .init(amountMultiplier: 1000))))
        // Not 1,000 × $884.61: rounding is not linear under scaling ($65 ÷ 3 vs $65,000 ÷ 3),
        // which is exactly why splits are recomputed rather than scaled.
        #expect(summary.position.net == usd("884613.33"))
    }
}

@Suite("Home summary")
struct HomeSummaryTests {
    @Test("Member who is owed: hero figures")
    func ownerPosition() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(referenceDate: reference)))
        #expect(summary.position.owedToYou == usd("914.30"))
        #expect(summary.position.youOwe == usd("29.69"))
        #expect(summary.position.net == usd("884.61"))
        #expect(summary.position.direction == .owed)
        #expect(summary.activeGroupCount == 4)
    }

    @Test("Attention is ordered: you owe before owed to you, larger first; settled groups excluded")
    func attentionOrder() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(referenceDate: reference)))
        #expect(summary.attention.map(\.group.name) == ["Apartment 4B", "Tahoe Ski Weekend", "Coastal Weekend Trip"])
        guard case .youOwe(let amount, let counterparties) = summary.attention[0].reason else {
            Issue.record("Expected youOwe"); return
        }
        #expect(amount == usd("29.69"))
        #expect(counterparties == [SampleLedger.Person.maya.id])
    }

    @Test("Person who owes overall")
    func owes() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(
            referenceDate: reference, options: .init(currentUser: .alexRivera))))
        #expect(summary.position.direction == .owe)
        #expect(summary.position.net == -usd("417.10"))
    }

    @Test("New user has no groups and an all-square position")
    func newUser() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.newUser()))
        #expect(!summary.hasGroups)
        #expect(summary.position.direction == .square)
        #expect(summary.recent.isEmpty)
    }

    @Test("Recent activity is limited, newest first, and only involves you")
    func recent() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(referenceDate: reference)))
        #expect(summary.recent.count == HomeSummaryBuilder.recentLimit)
        #expect(summary.recent.map(\.date) == summary.recent.map(\.date).sorted(by: >))
        #expect(!summary.recent.contains { $0.effect == .notInvolved })
    }

    @Test("Siri summary states direction in words, both sides, and pending payments")
    func speech() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(referenceDate: reference)))
        let text = BalanceSpeech.summary(summary, locale: Locale(identifier: "en_US"))
        #expect(text.contains("you're owed $884.61"))
        #expect(text.contains("Friends owe you $914.30, and you owe $29.69."))
        #expect(BalanceSpeech.summary(HomeSummaryBuilder.build(from: SampleLedger.newUser())!) == "You aren't in any groups yet.")
    }
}

@Suite("Activity feed")
struct ActivityFeedTests {
    let snapshot = SampleLedger.make(referenceDate: reference)
    let me = SampleLedger.Person.riley.id

    private func expense(_ title: String) -> Expense {
        snapshot.expenses.first { $0.title == title }!
    }

    @Test("Effects read from your perspective, across split methods and payers")
    func effects() {
        #expect(ActivityFeedBuilder.effect(of: expense("Beach house rental"), for: me) == .lent(usd("480.00")))
        #expect(ActivityFeedBuilder.effect(of: expense("Groceries for the house"), for: me) == .borrowed(usd("32.00")))
        #expect(ActivityFeedBuilder.effect(of: expense("Kayak tour"), for: me) == .lent(usd("55.00")))
        #expect(ActivityFeedBuilder.effect(of: expense("October utilities"), for: me) == .borrowed(usd("62.14")))
        #expect(ActivityFeedBuilder.effect(of: expense("Costco run"), for: me) == .lent(usd("64.90")))
    }

    @Test("Settlements read from your perspective")
    func settlementEffects() {
        let entries = ActivityFeedBuilder.entries(from: snapshot)
        let received = entries.first { $0.title == "Jordan paid you" }
        #expect(received?.effect == .receivedPayment(from: SampleLedger.Person.jordan.id, usd("10.78")))
        let paid = entries.first { $0.title == "You paid Alex M." }
        #expect(paid?.effect == .paidBack(to: SampleLedger.Person.alexMorgan.id, usd("39.00")))
    }

    @Test("Sections are titled Today, Yesterday, then dates")
    func sections() {
        let entries = ActivityFeedBuilder.entries(from: snapshot)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sections = ActivityFeedBuilder.sections(entries, now: reference, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(sections.first?.title == "Today")
        #expect(sections.dropFirst().first?.title == "Yesterday")
        #expect(sections.map(\.id) == sections.map(\.id).sorted(by: >))
        #expect(sections.flatMap(\.entries).count == entries.count)
    }

    @Test("Activity filters")
    func filters() {
        let entries = ActivityFeedBuilder.entries(from: snapshot)
        // Confirmed settlements plus the seeded "reported" payment event.
        #expect(entries.filter(ActivityFilter.payments.includes).count == snapshot.settlements.count + 1)
        #expect(entries.filter(ActivityFilter.all.includes).count == entries.count)
    }
}

@Suite("Identity presentation")
struct PersonIdentityTests {
    @Test("Initials", arguments: [
        ("Priya Natarajan", "PN"), ("Sam", "S"), ("María José García", "MG"),
    ])
    func initials(name: String, expected: String) {
        #expect(PersonIdentity.initials(for: name) == expected)
    }

    @Test("Short labels disambiguate shared first names instead of relying on initials")
    func disambiguation() {
        let morgan = Member(displayName: "Alex Morgan")
        let rivera = Member(displayName: "Alex Rivera")
        let maya = Member(displayName: "Maya Chen")
        let labels = PersonIdentity.shortLabels(for: [morgan, rivera, maya])
        #expect(labels[morgan.id] == "Alex M.")
        #expect(labels[rivera.id] == "Alex R.")
        #expect(labels[maya.id] == "Maya")
    }

    @Test("Identical full names fall back to handles")
    func identicalNames() {
        let first = Member(displayName: "Sam Lee", handle: "samlee")
        let second = Member(displayName: "Sam Lee", handle: "sam.l")
        let labels = PersonIdentity.shortLabels(for: [first, second])
        #expect(labels[first.id] == "Sam Lee (@samlee)")
        #expect(labels[second.id] == "Sam Lee (@sam.l)")
    }

    @Test("Lists put you first and truncate with a count")
    func lists() {
        let me = Member(displayName: "Riley Park")
        let others = ["Maya Chen", "Alex Morgan", "Jordan Brooks", "Sam Okafor"].map { Member(displayName: $0) }
        let text = PersonIdentity.list([others[0], me] + others.dropFirst(), currentUserID: me.id, maximumNames: 3)
        #expect(text.hasPrefix("you, Maya, "))
        #expect(text.contains("2 others"))
    }

    @Test("Counts inflect instead of reading \"1 groups\"")
    func inflection() {
        #expect(Inflect.string("Across ^[\(1) group](inflect: true)") == "Across 1 group")
        #expect(Inflect.string("Across ^[\(4) group](inflect: true)") == "Across 4 groups")
        #expect(Inflect.string("Review ^[\(2) request](inflect: true)") == "Review 2 requests")
    }

    @Test("Avatar colour bucket is stable across launches")
    func stableBucket() {
        let id = MemberID(UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000001")!)
        #expect(id.stableBucket(count: 8) == id.stableBucket(count: 8))
        #expect((0..<8).contains(id.stableBucket(count: 8)))
    }
}

@Suite("Home presentation")
@MainActor
struct HomePresentationTests {
    @Test("The owed share divides what's open, and is absent when nothing is")
    func owedShare() throws {
        let share = try #require(NetPosition(owedToYou: usd("75.00"), youOwe: usd("25.00")).owedShare)
        #expect(abs(share - 0.75) < 0.000_001)
        #expect(NetPosition(owedToYou: usd("0.00"), youOwe: usd("12.00")).owedShare == 0)
        #expect(NetPosition(owedToYou: .zero(), youOwe: .zero()).owedShare == nil)
    }

    @Test("Wallet cards never wear the same finish as the card behind them")
    func finishesDiffer() {
        let ids = (0..<40).map { _ in GroupID() }
        let finishes = SUWalletFinish.stack(ids)
        #expect(finishes.count == ids.count)
        for index in finishes.indices.dropFirst() {
            #expect(finishes[index] != finishes[index - 1])
        }
        #expect(!finishes.contains(.calm), "The calm finish is only for the all-square card")
    }

    @Test("A group keeps its finish wherever it sits, unless its neighbour already wears it")
    func finishIsStable() {
        let id = GroupID()
        #expect(SUWalletFinish.stack([id]) == [SUWalletFinish.for(id)])
        #expect(SUWalletFinish.for(id) == SUWalletFinish.for(id))
    }

    @Test("Card reasons stay short: names for one or two people, a count beyond that")
    func shortReasons() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: SampleLedger.make(referenceDate: reference)))
        let labels = PersonIdentity.shortLabels(for: Array(summary.members.values))
        for item in summary.attention {
            let text = item.shortReasonText(labels: labels)
            switch item.reason {
            case .owedToYou(_, let ids):
                #expect(text.hasSuffix(ids.count == 1 ? "owes you" : "owe you"), "\(text)")
                if ids.count > 2 { #expect(text.hasPrefix("\(ids.count) people")) }
            case .youOwe(_, let ids):
                #expect(text.hasPrefix("You owe"), "\(text)")
                if ids.count > 2 { #expect(text == "You owe \(ids.count) people") }
            }
            #expect(item.signedAmountText.first == "+" || item.signedAmountText.first == "\u{2212}")
        }
    }
}
