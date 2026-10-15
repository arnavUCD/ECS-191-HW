import Foundation
@testable import SquareUp
import Testing

private func usd(_ text: String) -> Money { Money(string: text)! }
private let reference = DemoScenario.fixedReferenceDate
private let us = Locale(identifier: "en_US")

@Suite("Add expense flow")
@MainActor
struct ComposeExpenseModelTests {
    let snapshot = SampleLedger.make(referenceDate: reference)
    let riley = SampleLedger.Person.riley.id
    let maya = SampleLedger.Person.maya.id
    let jordan = SampleLedger.Person.jordan.id

    private func model(group: SampleLedger.GroupKey = .apartment) -> ComposeExpenseModel {
        let model = ComposeExpenseModel(request: ComposerRequest(groupID: group.id), locale: us)
        model.load(snapshot: snapshot)
        return model
    }

    private func type(_ amount: String, into model: ComposeExpenseModel) {
        for character in amount {
            if character == "." { model.press(.decimalSeparator) } else { model.press(.digit(character.wholeNumberValue!)) }
        }
    }

    @Test("Opens on the requested group with you paying and everyone participating")
    func defaults() {
        let model = model()
        #expect(model.group?.id == SampleLedger.GroupKey.apartment.id)
        #expect(model.payerID == riley)
        #expect(model.participantIDs == [riley, maya, jordan])
        #expect(model.amountStepIssue == "Enter an amount")
    }

    @Test("Amount step requires an amount and a description")
    func amountStep() {
        let model = model()
        type("84", into: model)
        #expect(model.amountStepIssue == "Add what it was for")
        model.advance()
        #expect(model.step == .amount)
        model.title = "Dinner at Nopa"
        #expect(model.category == .food, "Category is suggested from the description")
        model.advance()
        #expect(model.step == .split)
    }

    @Test("An explicit category is never overwritten by later typing")
    func explicitCategory() {
        let model = model()
        model.chooseCategory(.entertainment)
        model.title = "Dinner"
        #expect(model.category == .entertainment)
    }

    @Test("Equal split builds a reconciled expense")
    func equalSplit() throws {
        let model = model()
        type("100", into: model)
        model.title = "Groceries"
        #expect(model.reconciliation.isBalanced)
        let expense = try model.buildExpense(now: reference)
        #expect(expense.allocations.map(\.amount) == ["33.34", "33.33", "33.33"].map(usd))
        #expect(expense.payments == [Share(riley, usd("100.00"))])
        try ExpenseValidator.validate(expense, in: model.group!)
        let sentence = try #require(model.sentence)
        #expect(sentence.headline == "You paid $100.00 for Groceries.")
        #expect(sentence.roundingNote == "You pay $0.01 more so the total matches exactly.")
        #expect(sentence.effect.contains("will owe you $66.66"))
    }

    @Test("Exact amounts report what's left, what's over, and can fill the remainder")
    func exactSplit() {
        let model = model()
        type("60", into: model)
        model.title = "Wine"
        model.method = .exact
        model.exactText[riley] = "10"
        #expect(model.reconciliation.state == .remaining(usd("50.00")))
        #expect(!model.canContinueFromSplit)
        model.exactText[maya] = "70"
        #expect(model.reconciliation.state == .over(usd("20.00")))
        model.exactText[maya] = ""
        model.distributeRemainingExact()
        #expect(model.reconciliation.isBalanced)
        #expect(model.parsedExact(maya) == usd("25.00"))
        #expect(model.canContinueFromSplit)
        model.exactText[jordan] = "abc"
        #expect(model.reconciliation.state == .incomplete(.unreadableValue))
    }

    @Test("Percentages must reach exactly 100")
    func percentageSplit() {
        let model = model()
        type("80", into: model)
        model.title = "Cleaning"
        model.method = .percentage
        model.percentText = [riley: "50", maya: "25", jordan: "20"]
        #expect(model.reconciliation.state == .percentRemaining(5))
        model.percentText[jordan] = "25%"
        #expect(model.reconciliation.isBalanced)
        #expect(model.computedShare(for: riley) == usd("40.00"))
    }

    @Test("Share-based split and zero-share guard")
    func shareSplit() {
        let model = model()
        type("90", into: model)
        model.title = "Cabin"
        model.method = .shares
        model.shareWeights = [riley: 2, maya: 1, jordan: 0]
        #expect(model.computedShare(for: riley) == usd("60.00"))
        #expect(model.computedShare(for: jordan) == .zero())
        model.shareWeights = [riley: 0, maya: 0, jordan: 0]
        #expect(model.reconciliation.state == .incomplete(.zeroShares))
    }

    @Test("Participants keep group order and an empty selection is blocked")
    func participants() {
        let model = model()
        type("30", into: model)
        model.toggleParticipant(riley)
        model.toggleParticipant(riley)
        #expect(model.participantIDs == [riley, maya, jordan])
        model.setAllParticipants(false)
        #expect(model.reconciliation.state == .incomplete(.noParticipants))
        #expect(!model.canContinueFromSplit)
    }

    @Test("Switching groups resets payer, participants, and per-person inputs")
    func switchingGroups() {
        let model = model()
        model.exactText[maya] = "5"
        model.selectGroup(SampleLedger.GroupKey.tahoe.id)
        #expect(model.participantIDs.count == 5)
        #expect(model.exactText.isEmpty)
        #expect(model.payerID == riley)
    }

    @Test("Suggestions fill a draft, are marked, and clear when edited")
    func suggestions() {
        let model = model()
        let suggestion = QuickEntrySuggestion(
            amount: usd("45.00"), title: "Pizza", payerID: maya, participantIDs: [jordan, riley],
            warnings: [.unknownPerson("Zed")], provider: RuleBasedQuickEntryProvider().descriptor
        )
        model.apply(suggestion)
        #expect(model.total == usd("45.00"))
        #expect(model.payerID == maya)
        #expect(model.participantIDs == [riley, jordan])
        #expect(model.suggestedFields == [.amount, .title, .payer, .participants])
        model.title = "Pizza night"
        model.press(.digit(1))
        #expect(!model.suggestedFields.contains(.title))
        #expect(!model.suggestedFields.contains(.amount))
        #expect(model.step == .amount, "A suggestion never advances or saves on its own")
        #expect(model.saveState == .idle)
    }

    @Test("Saving persists through the repository and changes Home")
    func savesAndUpdatesHome() async throws {
        let store = InMemoryLedgerStore(snapshot)
        let model = model()
        type("30", into: model)
        model.title = "Pizza"
        let saved = await model.save(to: store, now: reference)
        #expect(saved)
        #expect(model.saveState == .saved)
        #expect(store.revision == 1)
        let summary = try #require(await HomeSummaryBuilder.build(from: try store.snapshot()))
        #expect(summary.position.youOwe == usd("9.69"), "Maya now owes Riley $10 less net")
        #expect(summary.recent.first?.title == "Pizza")
        #expect(await model.save(to: store, now: reference) == false, "Saving twice is prevented")
    }

    @Test("A storage failure is reported and nothing is marked saved")
    func saveFailure() async {
        let store = InMemoryLedgerStore(snapshot)
        store.failure = .storage("Disk")
        let model = model()
        type("30", into: model)
        model.title = "Pizza"
        #expect(await model.save(to: store, now: reference) == false)
        guard case .failed(let message) = model.saveState else { Issue.record("Expected failure"); return }
        #expect(message.contains("Nothing was changed"))
    }
}

@Suite("Review sentence")
struct ExpenseSentenceTests {
    let members = [
        Member(id: MemberID(UUID(uuidString: "10000000-0000-4000-8000-000000000001")!), displayName: "Riley Park"),
        Member(id: MemberID(UUID(uuidString: "10000000-0000-4000-8000-000000000002")!), displayName: "Maya Chen"),
        Member(id: MemberID(UUID(uuidString: "10000000-0000-4000-8000-000000000003")!), displayName: "Alex Morgan"),
    ]

    @Test("Someone else paid: you owe them your share")
    func otherPayer() throws {
        let shares = try SplitCalculator.equal(usd("84.00"), among: members.map(\.id))
        let sentence = ExpenseSentence.make(
            title: "Dinner", total: usd("84.00"), payments: [Share(members[1].id, usd("84.00"))], shares: shares.shares, method: .equal,
            roundingAdjustments: shares.roundingAdjustments, currentUserID: members[0].id, members: members, locale: us
        )
        #expect(sentence.headline == "Maya paid $84.00 for Dinner.")
        #expect(sentence.split == "Split equally between you, Maya, and Alex — $28.00 each.")
        #expect(sentence.effect == "You'll owe Maya $28.00.")
        #expect(sentence.roundingNote == nil)
    }

    @Test("You are not part of it")
    func notInvolved() throws {
        let shares = try SplitCalculator.equal(usd("20.00"), among: [members[2].id])
        let sentence = ExpenseSentence.make(
            title: "Taxi", total: usd("20.00"), payments: [Share(members[1].id, usd("20.00"))], shares: shares.shares, method: .equal,
            roundingAdjustments: [:], currentUserID: members[0].id, members: members, locale: us
        )
        #expect(sentence.effect == "You're not part of this expense.")
    }
}
