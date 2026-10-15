import Foundation
@testable import SquareUp
import Testing

@Suite("M3 receipt feature models and language")
@MainActor
struct ReceiptFeatureModelTests {
    private func reviewModel(_ rows: [(String, String?)] = ReceiptFixtures.dinner) throws -> ReceiptReviewModel {
        var harness = RoomHarness()
        try harness.run(.createDraft(harness.roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
        try harness.run(.saveDraft(harness.roomID, expectedRevision: 1, receipt: ReceiptFixtures.draft(rows), groupID: nil, payerID: nil))
        return ReceiptReviewModel(room: harness.room, snapshot: harness.engine.state, now: DemoScenario.fixedReferenceDate)
    }

    @Test("Typed amounts are never rounded: extra decimals are rejected")
    func amountInput() {
        let locale = Locale(identifier: "en_US")
        #expect(ReceiptAmountInput.parse("8.5", currency: .usd, allowsNegative: false, locale: locale) == dollars("8.50"))
        #expect(ReceiptAmountInput.parse("$1,234.56", currency: .usd, allowsNegative: false, locale: locale) == dollars("1234.56"))
        #expect(ReceiptAmountInput.parse("-4", currency: .usd, allowsNegative: true, locale: locale) == dollars("-4.00"))
        #expect(ReceiptAmountInput.parse("-4", currency: .usd, allowsNegative: false, locale: locale) == nil)
        #expect(ReceiptAmountInput.parse("8.505", currency: .usd, allowsNegative: false, locale: locale) == nil)
        #expect(ReceiptAmountInput.parse("abc", currency: .usd, allowsNegative: false, locale: locale) == nil)
        #expect(ReceiptAmountInput.text(dollars("-4.00"), locale: locale) == "-4.00")
    }

    @Test("Continue needs exact math only; the group and payer are chosen on the next step")
    func continueGate() throws {
        let review = try reviewModel()
        #expect(review.canContinue, "No group yet: the receipt can still go to a group or be split now")
        #expect(review.groupID == nil)
        review.setGroup(Groups.friday)
        #expect(review.payerID == People.riley)
        #expect(review.canContinue)
        review.setTotal(dollars("100.00"))
        #expect(!review.canContinue)
        #expect(review.blockers.contains { $0.contains("$4.04 more than the total") })
    }

    @Test("Edits are attributed and keep the original proposal")
    func attribution() throws {
        let review = try reviewModel()
        let item = review.draft.items[0]
        review.updateItem(item.id, name: "Truffle Fries (large)", quantity: 1, unitPrice: nil, lineTotal: dollars("9.50"), isRefund: false)
        let edited = try #require(review.draft.item(item.id))
        #expect(edited.name.value == "Truffle Fries (large)")
        #expect(edited.name.proposed == "Truffle Fries")
        #expect(edited.name.editedBy == People.riley)
        #expect(edited.proposal?.name == "Truffle Fries")
    }

    @Test("Merge, split, move, add, and delete lines")
    func lineOperations() throws {
        let review = try reviewModel()
        let first = review.draft.items[0].id
        review.mergeWithNext(first)
        #expect(review.draft.items[0].name.value == "Truffle Fries Margherita Pizza")
        #expect(review.draft.items[0].amount == dollars("25.50"))
        #expect(review.draft.items.count == 7)
        review.split(first, firstAmount: dollars("9.50"))
        #expect(review.draft.items.map(\.amount).prefix(2) == [dollars("9.50"), dollars("16.00")])
        #expect(ReceiptValidator.reconcile(review.draft).isReconciled, "Merging and splitting never changes the sum")
        let added = review.addItem()
        #expect(ReceiptValidator.reconcile(review.draft).issues.contains { $0.kind == .itemNameBlank(added) })
        review.moveItem(added, by: -1)
        #expect(review.draft.items[review.draft.items.count - 2].id == added)
        review.deleteItem(added)
        #expect(review.draft.item(added) == nil)
    }

    @Test("Currency changes relabel without rounding and are limited to same-precision currencies")
    func currency() throws {
        let review = try reviewModel()
        #expect(!review.currencyChoices.contains(.jpy))
        review.setCurrency(.eur)
        #expect(review.draft.items[0].amount == Money(9.50, .eur))
        #expect(review.draft.total.value == Money(104.04, .eur))
        #expect(ReceiptValidator.reconcile(review.draft).isReconciled)
    }

    @Test("Room summary: claim states, filters, the acting person's share, and identities")
    func roomSummary() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claim("Shared Nachos", .share, as: People.maya)
        try room.claim("Shared Nachos", .share, as: People.priya)
        try room.claim("Tiramisu", as: People.maya)
        try room.run(.dispute(room.roomID, expectedRevision: room.revision, .item(room.item("Lemonade").id), note: nil), as: People.priya)
        let summary = ReceiptRoomSummary.make(room: room.room, snapshot: room.engine.state, actorID: People.maya)
        #expect(summary.isActorHost == false)
        #expect(summary.identities.map(\.id) == [People.riley, People.maya, People.alexMorgan, People.priya])
        let nachos = try #require(summary.lines.first { $0.item.name.value == "Shared Nachos" })
        #expect(nachos.state == .shared([People.maya, People.priya]))
        #expect(nachos.yourShare == dollars("6.00"))
        #expect(summary.stateText(nachos) == "Shared by you and Priya")
        #expect(summary.count(.mine) == 2)
        #expect(summary.count(.shared) == 1)
        #expect(summary.count(.disputed) == 1)
        #expect(summary.count(.unclaimed) == 5)
        #expect(summary.you.items == dollars("14.50"))
        #expect(summary.you.total.isPositive)
    }

    @Test("Final statement names the payer, everyone who owes, and the payer's own share")
    func finalStatement() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claimEverything()
        let allocation = ReceiptAllocationEngine.allocate(room.room)
        let names = ReceiptLanguage.names(room.engine.state.members)
        let text = ReceiptLanguage.finalStatement(room: room.room, allocation: allocation, names: names, currentUserID: People.riley,
                                                  locale: Locale(identifier: "en_US"))
        #expect(text.hasPrefix("The $104.04 receipt is fully assigned. You paid, "))
        #expect(text.contains("Maya owes $"))
        #expect(text.contains("your own share is $"))
        let total = allocation.participants.map(\.total).sum(in: .usd)
        #expect(total == dollars("104.04"))
    }

    @Test("Every readiness issue and room error has plain-language text")
    func language() throws {
        var room = RoomHarness()
        try room.openDinner()
        let names = ReceiptLanguage.names(room.engine.state.members)
        for issue in ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state) {
            #expect(!ReceiptLanguage.readiness(issue, room: room.room, names: names).isEmpty)
        }
        #expect(ReceiptLanguage.error(.itemAlreadyClaimed(by: People.maya), names: names) == "Maya already claimed this. Share it or dispute it instead.")
        #expect(LedgerErrorMessages.text(for: .receipt(.staleRevision(current: 3))).contains("changed while you were looking"))
        for event in room.room.history {
            #expect(!ReceiptLanguage.history(event, room: room.room, names: names).isEmpty)
        }
    }

    @Test("Home and group detail list receipts in progress; finalized rooms leave the list")
    func unfinishedLists() throws {
        var room = RoomHarness()
        try room.openDinner()
        let home = try #require(HomeSummaryBuilder.build(from: room.engine.state))
        #expect(home.unfinishedReceipts.map(\.id).contains(room.roomID)) // alongside the sample's open room
        let group = try GroupSummaryBuilder.detail(for: Groups.friday, in: room.engine.state)
        #expect(group.unfinishedRooms.map(\.id) == [room.roomID])
        try room.claimEverything()
        try room.run(.transition(room.roomID, expectedRevision: room.revision, .requestFinalReview))
        try room.run(.finalize(room.roomID, expectedRevision: room.revision))
        #expect(!room.engine.state.unfinishedRooms.contains { $0.id == room.roomID })
        let detail = try ExpenseDetailSummary.make(expenseID: try #require(room.room.finalExpenseID), from: room.engine.state)
        #expect(detail.receiptRoom?.id == room.roomID)
        #expect(detail.history.contains { if case .receiptRoomFinalized = $0.kind { true } else { false } })
    }

    @Test("Deep link opens the scan flow, optionally for a group")
    func deepLink() {
        let url = DeepLink.scanReceipt(Groups.friday).url
        #expect(DeepLink.parse(url) == .scanReceipt(Groups.friday))
        let router = AppRouter()
        router.open(.scanReceipt(nil))
        #expect(router.receiptFlow?.start == .new(groupID: nil))
    }
}
