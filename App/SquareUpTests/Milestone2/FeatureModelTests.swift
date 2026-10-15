import Foundation
@testable import SquareUp
import Testing

@Suite("M2.2 Composer: edit and multiple payers")
@MainActor
struct ComposerM2Tests {
    @Test("Editing starts from saved values and summarises changes before saving")
    func editPrefill() async throws {
        let snapshot = sample()
        let costco = expense("Costco run", in: snapshot)
        let model = ComposeExpenseModel(request: ComposerRequest(editingExpenseID: costco.id), locale: Locale(identifier: "en_US"))
        model.load(snapshot: snapshot)
        #expect(model.isEditing)
        #expect(model.total == dollars("97.35"))
        #expect(model.title == "Costco run")
        #expect(model.payerID == People.riley)
        #expect(model.method == .equal)
        #expect(model.changeSummary?.hasChanges == false)
        #expect(!model.hasChanges)

        model.title = "Costco (bulk)"
        model.toggleParticipant(People.jordan)
        let changes = try #require(model.changeSummary)
        #expect(changes.fields == [.title, .participants])
        #expect(model.sentence?.split == "Split equally between you and Maya — $48.68 each." || model.sentence?.split.hasPrefix("Split equally between you and Maya") == true)

        let store = InMemoryLedgerStore(snapshot)
        #expect(await model.save(to: store, now: DemoScenario.fixedReferenceDate))
        let saved = try #require(try await store.snapshot().expense(costco.id))
        #expect(saved.revision == 2)
        #expect(saved.title == "Costco (bulk)")
        #expect(saved.createdAt == costco.createdAt, "Edits keep the original creation time and date")
        #expect(saved.date == costco.date)
    }

    @Test("Non-equal splits reopen as their saved exact amounts")
    func editExact() {
        var snapshot = sample()
        let custom = Expense(groupID: Groups.apartment, title: "Rent share", date: DemoScenario.fixedReferenceDate, total: dollars("100.00"),
                             category: .housing, splitMethod: .percentage, payments: [Share(People.riley, dollars("100.00"))],
                             allocations: [Share(People.riley, dollars("50.00")), Share(People.maya, dollars("30.00")), Share(People.jordan, dollars("20.00"))],
                             createdBy: People.riley)
        snapshot = snapshot.adding(custom)
        let model = ComposeExpenseModel(request: ComposerRequest(editingExpenseID: custom.id), locale: Locale(identifier: "en_US"))
        model.load(snapshot: snapshot)
        #expect(model.method == .exact)
        #expect(model.parsedExact(People.maya) == dollars("30.00"))
        #expect(model.reconciliation.isBalanced)
        #expect(model.changeSummary?.fields == [.split], "Only the method label differs; amounts are identical")
    }

    @Test("Multiple payers must add up to the total")
    func multiplePayers() throws {
        let model = ComposeExpenseModel(request: ComposerRequest(groupID: Groups.apartment), locale: Locale(identifier: "en_US"))
        model.load(snapshot: sample())
        for key: AmountEntry.Key in [.digit(9), .digit(0)] { model.press(key) }
        model.title = "Dinner"
        model.setMultiplePayers(true)
        #expect(model.payerAmountText[People.riley] == "90.00", "Starts with the whole amount on the current payer")
        model.payerAmountText[People.riley] = "60"
        #expect(model.payerReconciliation.state == .remaining(dollars("30.00")))
        #expect(!model.canContinueFromSplit)
        model.payerAmountText[People.maya] = "30"
        #expect(model.payerReconciliation.isBalanced)
        #expect(model.canContinueFromSplit)
        let expense = try model.buildExpense(now: DemoScenario.fixedReferenceDate)
        #expect(Set(expense.payments) == [Share(People.riley, dollars("60.00")), Share(People.maya, dollars("30.00"))])
        #expect(model.sentence?.headline == "You and Maya paid $90.00 for Dinner.")
        model.payerAmountText[People.maya] = "40"
        #expect(model.payerReconciliation.state == .over(dollars("10.00")))
    }

    @Test("Removed members don't appear in new expenses but stay on edited ones")
    func removedMembers() throws {
        var harness = EngineHarness(sample())
        try harness.run(.removeMember(Groups.friday, People.maya))
        let fresh = ComposeExpenseModel(request: ComposerRequest(groupID: Groups.friday))
        fresh.load(snapshot: harness.state)
        #expect(!fresh.members.contains { $0.id == People.maya })
        let edit = ComposeExpenseModel(request: ComposerRequest(editingExpenseID: expense("Nopa dinner", in: harness.state).id))
        edit.load(snapshot: harness.state)
        #expect(edit.members.contains { $0.id == People.maya })
    }

    @Test("Editing a deleted expense is refused")
    func deletedCantEdit() throws {
        var harness = EngineHarness(sample())
        let wifi = expense("Wi-Fi", in: harness.state)
        try harness.run(.deleteExpense(wifi.id))
        let model = ComposeExpenseModel(request: ComposerRequest(editingExpenseID: wifi.id))
        model.load(snapshot: harness.state)
        #expect(model.loadError == .rule(.expenseNotFound))
    }
}

@Suite("M2.1 Group editor model")
@MainActor
struct GroupEditorModelTests {
    @Test("Create: typed and known people, inline validation, and save")
    func create() async throws {
        let store = InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate })
        let model = GroupEditorModel(request: .create)
        await model.load(from: store)
        #expect(await model.save(using: store) == nil)
        #expect(model.nameError != nil, "Empty name shows an inline error after trying to save")

        model.name = "Weekend Trip"
        model.memberName = "Taylor Kim"
        model.memberHandle = "bad handle"
        #expect(!model.queueTypedMember())
        #expect(model.memberMessage != nil)
        model.memberHandle = "tkim"
        #expect(model.queueTypedMember())
        model.pickExisting(try #require(model.knownPeople.first { $0.id == People.maya }))
        model.memberName = "Sam Lee" // typed but not added — included on save
        let id = try #require(await model.save(using: store))
        let group = try #require(try await store.snapshot().group(id))
        #expect(group.memberIDs.count == 4)
        #expect(model.saveState == .saved(id))
    }

    @Test("Edit: removal blocked with an explanation; currency locked")
    func edit() async throws {
        let store = InMemoryLedgerStore(sample(), now: { DemoScenario.fixedReferenceDate })
        let model = GroupEditorModel(request: .edit(Groups.apartment))
        await model.load(from: store)
        #expect(model.name == "Apartment 4B")
        #expect(model.isCurrencyLocked)
        let maya = try #require(model.activeMembers.first { $0.id == People.maya })
        await model.remove(maya, using: store)
        #expect(model.memberMessage == "Maya Chen is still owed $70.16. Settle up before removing them.")
        #expect(model.activeMembers.contains { $0.id == People.maya })
    }
}

@Suite("M2.6 Home and activity")
struct HomePaymentsTests {
    @Test("Home surfaces payments to confirm, unfinished handoffs, and your pending reports")
    func homeCards() throws {
        var harness = EngineHarness(sample())
        var summary = try #require(HomeSummaryBuilder.build(from: harness.state))
        #expect(summary.paymentsToConfirm.map(\.payerID) == [People.alexRivera])
        #expect(PaymentStatusLanguage.recipientQuestion(for: summary.paymentsToConfirm[0], members: harness.state.members,
                                                        locale: Locale(identifier: "en_US"))
                == "Alex Rivera reported paying you $417.10 through Venmo. Did you receive it?")

        let attempt = try #require(try harness.run(.startPayment(PaymentRequest(
            groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya, amount: dollars("29.69"),
            provider: .appleCash, destinationID: nil
        ))).attempt)
        try harness.run(.advancePayment(attempt.id, .openHandoff))
        summary = try #require(HomeSummaryBuilder.build(from: harness.state))
        #expect(summary.unfinishedPayments.map(\.id) == [attempt.id], "Return prompt survives relaunch (it's persisted state)")
        #expect(PaymentStatusLanguage.returnQuestion(for: attempt, members: harness.state.members, locale: Locale(identifier: "en_US"))
            == "Did you send $29.69 to Maya?")

        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        summary = try #require(HomeSummaryBuilder.build(from: harness.state))
        #expect(summary.unfinishedPayments.isEmpty)
        #expect(summary.awaitingOthers.map(\.id) == [attempt.id])
    }

    @Test("Settle up targets a group you owe in first")
    func settleUpTarget() throws {
        let summary = try #require(HomeSummaryBuilder.build(from: sample()))
        #expect(HomeSummaryBuilder.settleUpTarget(in: summary) == Groups.apartment)
    }

    @Test("Activity shows edits, deletions, membership, and payment events in human language")
    func activityEvents() throws {
        var harness = EngineHarness(sample())
        try harness.run(.deleteExpense(expense("Wi-Fi", in: harness.state).id))
        try harness.run(.removeMember(Groups.friday, People.priyaID))
        let entries = ActivityFeedBuilder.entries(from: harness.state)
        let titles = entries.compactMap(\.eventDescription?.title)
        #expect(titles.contains("You deleted Wi-Fi"))
        #expect(titles.contains("You removed Priya"))
        #expect(titles.contains("Alex R. reported paying you"))
        #expect(!entries.contains { if case .expense(let id) = $0.kind { id == expense("Wi-Fi", in: harness.state).id } else { false } },
                "Deleted expenses leave the ledger feed")
        #expect(entries.filter(ActivityFilter.expenses.includes).contains { $0.eventCategory == .expense })
        #expect(entries.filter(ActivityFilter.payments.includes).contains { $0.eventCategory == .payment })
    }

    @Test("Paying summary: recipient's enabled methods, preferred first; nothing owed after reporting")
    func payingSummary() throws {
        var harness = EngineHarness(sample())
        let summary = try PayingSummary.make(groupID: Groups.apartment, recipientID: People.maya, from: harness.state)
        #expect(summary.amount == dollars("29.69"))
        #expect(summary.destinations.first?.provider == .appleCash)
        #expect(summary.destinations.map(\.provider) == [.appleCash, .paypal, .cashApp, .zelle])
        let sam = try PayingSummary.make(groupID: Groups.tahoe, recipientID: People.sam, from: harness.state)
        #expect(sam.destinations.isEmpty, "Sam demonstrates the no-method state")

        let attempt = try #require(try harness.run(.startPayment(PaymentRequest(
            groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya, amount: dollars("29.69"),
            provider: .other, destinationID: nil
        ))).attempt)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        let after = try PayingSummary.make(groupID: Groups.apartment, recipientID: People.maya, from: harness.state)
        #expect(after.amount == nil)
        #expect(after.pending.map(\.id) == [attempt.id])
    }
}

extension People {
    static let priyaID = SampleLedger.Person.priya.id
}

extension LedgerSnapshot {
    func adding(_ expense: Expense) -> LedgerSnapshot {
        LedgerEngine.apply([.upsertExpense(expense)], to: self)
    }
}

@Suite("M2.6 Payment status language")
struct PaymentStatusLanguageTests {
    @Test("Headlines read naturally for payer, recipient, and observers")
    func headlines() throws {
        var harness = EngineHarness(sample())
        let attempt = try #require(try harness.run(.startPayment(PaymentRequest(
            groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya, amount: dollars("29.69"),
            provider: .appleCash, destinationID: nil
        ))).attempt)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        try harness.run(.advancePayment(attempt.id, .dispute(reason: nil)), as: People.maya)
        let disputed = try #require(harness.state.attempt(attempt.id))
        let members = harness.state.members
        #expect(PaymentStatusLanguage.headline(for: disputed, members: members, currentUserID: People.riley) == "Your payment to Maya is disputed")
        #expect(PaymentStatusLanguage.headline(for: disputed, members: members, currentUserID: People.maya) == "Riley's payment to you is disputed")
        try harness.run(.advancePayment(attempt.id, .reject(reason: nil)), as: People.maya)
        let rejected = try #require(harness.state.attempt(attempt.id))
        #expect(PaymentStatusLanguage.headline(for: rejected, members: members, currentUserID: People.riley) == "Your payment to Maya wasn't received")
        #expect(PaymentStatusLanguage.timelineLabel(for: .handoffOpened, provider: .appleCash) == "Opened Apple Cash")
    }
}
