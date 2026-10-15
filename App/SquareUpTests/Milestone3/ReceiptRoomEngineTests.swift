import Foundation
@testable import SquareUp
import Testing

@Suite("M3 Live Receipt Room engine")
struct ReceiptRoomEngineTests {
    private func error(_ body: () throws -> Void) -> ReceiptRoomError? {
        do {
            try body()
            return nil
        } catch {
            if case .receipt(let receiptError)? = error as? LedgerError { return receiptError }
            return nil
        }
    }

    @Test("Draft → ready → open, with group, payer, and receipt validity enforced")
    func lifecycle() throws {
        var room = RoomHarness()
        try room.run(.createDraft(room.roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
        #expect(room.room.state == .draft)
        #expect(room.room.hostID == People.riley)
        // An unreviewed (empty) draft can't be confirmed.
        #expect(error { try room.run(.confirmReceipt(room.roomID, expectedRevision: room.revision)) } == .groupRequired)
        try room.run(.saveDraft(room.roomID, expectedRevision: room.revision, receipt: ReceiptFixtures.draft([("Cafe", nil), ("Tea", "3.00"), ("TOTAL", "4.00")]),
                                groupID: room.group, payerID: People.riley))
        guard case .receiptNotReady(let issues)? = error({ try room.run(.confirmReceipt(room.roomID, expectedRevision: room.revision)) }) else {
            Issue.record("Expected receiptNotReady")
            return
        }
        #expect(issues == [.totalMismatch(difference: dollars("1.00"))])
        // Claiming isn't possible before the room opens.
        #expect(error { try room.run(.claim(room.roomID, expectedRevision: room.revision, item: room.room.receipt.items[0].id, .mine)) }
            == .notAllowedInState(.draft))

        var dinner = RoomHarness()
        try dinner.openDinner()
        #expect(dinner.room.state == .open)
        #expect(dinner.room.participantIDs == [People.riley, People.maya, People.alexMorgan, People.priya])
        #expect(dinner.engine.state.events.last?.kind == .receiptRoomOpened(dinner.roomID, title: "FERNWOOD SUPPER CLUB", participantCount: 4))
    }

    @Test("Stale revisions are refused so older views can't overwrite newer state")
    func staleRevision() throws {
        var room = RoomHarness()
        try room.openDinner()
        let seen = room.revision
        try room.claim("Tiramisu", as: People.priya)
        // Maya acts on the revision she loaded before Priya's claim.
        #expect(error { try room.run(.claim(room.roomID, expectedRevision: seen, item: room.item("Tiramisu").id, .mine), as: People.maya) }
            == .staleRevision(current: room.revision))
        #expect(room.room.claims(for: room.item("Tiramisu").id).map(\.memberID) == [People.priya])
    }

    @Test("Mine, Share, and Undo; conflicting claims point to sharing or disputing")
    func claims() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claim("Shared Nachos", as: People.maya)
        #expect(error { try room.claim("Shared Nachos", as: People.priya) } == .itemAlreadyClaimed(by: People.maya))
        try room.claim("Shared Nachos", .share, as: People.priya)
        let nachos = room.item("Shared Nachos").id
        #expect(room.room.claims(for: nachos).map(\.mode) == [.equalShare, .equalShare], "Maya's full claim became an equal share")
        // Claiming twice is idempotent.
        let revision = room.revision
        try room.claim("Shared Nachos", .share, as: People.priya)
        #expect(room.revision == revision)
        // Undo leaves Maya's share covering the whole item again.
        try room.run(.unclaim(room.roomID, expectedRevision: room.revision, item: nachos), as: People.priya)
        let allocation = ReceiptAllocationEngine.allocate(room.room).item(nachos)
        #expect(allocation?.shares == [Share(People.maya, dollars("12.00"))])
        #expect(error { try room.run(.unclaim(room.roomID, expectedRevision: room.revision, item: nachos), as: People.priya) } == .noClaimToRemove)
        // Someone outside the room can't claim.
        #expect(error { try room.claim("Tiramisu", as: People.jordan) } == .notAParticipant)
    }

    @Test("Roles: identity switching never grants host permissions")
    func authorization() throws {
        var room = RoomHarness()
        try room.openDinner()
        let tip = room.charge(.tip).id
        #expect(error { try room.run(.setChargeAllocation(room.roomID, expectedRevision: room.revision, tip, .payer), as: People.maya) } == .hostOnly)
        #expect(error { try room.run(.transition(room.roomID, expectedRevision: room.revision, .beginResolving), as: People.maya) } == .hostOnly)
        #expect(error { try room.run(.finalize(room.roomID, expectedRevision: room.revision), as: People.maya) } == .hostOnly)
        // A participant can't divide an item among people who haven't claimed it.
        let split = ItemSplit.equal([People.maya, People.priya])
        #expect(error { try room.run(.setItemSplit(room.roomID, expectedRevision: room.revision, item: room.item("Lemonade").id, split), as: People.maya) }
            == .cannotIncludeOthers)
        // The host can assign anyone.
        try room.run(.setItemSplit(room.roomID, expectedRevision: room.revision, item: room.item("Lemonade").id, split))
        guard case .itemAssigned = room.room.history.last?.kind else {
            Issue.record("Expected an assignment event")
            return
        }
        #expect(room.room.history.last?.actorID == People.riley)
        // Resolving locks participant claims; the host can still assign.
        try room.run(.transition(room.roomID, expectedRevision: room.revision, .beginResolving))
        #expect(error { try room.claim("Tiramisu", as: People.priya) } == .notAllowedInState(.resolving))
        try room.claim("Tiramisu", as: People.riley)
    }

    @Test("Disputes block finalization until the host resolves or dismisses with a note")
    func disputes() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claimEverything()
        let fries = room.item("Truffle Fries").id
        try room.run(.dispute(room.roomID, expectedRevision: room.revision, .item(fries), note: "I only had a couple"), as: People.maya)
        let dispute = try #require(room.room.openDisputes.first)
        #expect(dispute.raisedBy == People.maya)
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state) == [.openDispute(dispute.id)])
        guard case .notReadyToFinalize = error({ try room.run(.transition(room.roomID, expectedRevision: room.revision, .requestFinalReview)) }) else {
            Issue.record("Expected readiness failure")
            return
        }
        #expect(error { try room.run(.resolveDispute(room.roomID, expectedRevision: room.revision, dispute.id, .dismissed, note: nil)) } == .noteRequired)
        try room.run(.setItemSplit(room.roomID, expectedRevision: room.revision, item: fries,
                                   .shares([MemberWeight(People.riley, 3), MemberWeight(People.maya, 1)])))
        try room.run(.resolveDispute(room.roomID, expectedRevision: room.revision, dispute.id, .resolved, note: "Split 3:1"))
        #expect(room.room.openDisputes.isEmpty)
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state).isEmpty)
    }

    @Test("Readiness names every unclaimed item and the remaining amount")
    func readiness() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claim("Truffle Fries", as: People.riley)
        let issues = ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state)
        #expect(issues.filter { if case .unclaimedItem = $0 { true } else { false } }.count == 7)
        let allocation = ReceiptAllocationEngine.allocate(room.room)
        #expect(!allocation.isComplete)
        #expect(allocation.remaining?.isPositive == true)
    }

    @Test("Finalization creates exactly one normal itemized expense, idempotently")
    func finalize() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claimEverything()
        try room.run(.transition(room.roomID, expectedRevision: room.revision, .requestFinalReview))
        #expect(room.room.state == .readyToFinalize)
        let revision = room.revision
        let first = try room.run(.finalize(room.roomID, expectedRevision: revision))
        let expenseID = try #require(first.expenseID)
        // A double tap or retry — even with the old revision — changes nothing.
        let second = try room.run(.finalize(room.roomID, expectedRevision: revision))
        #expect(second.isNoOp)
        #expect(second.expenseID == expenseID)
        let expenses = room.engine.state.allExpenses.filter { $0.id == expenseID }
        #expect(expenses.count == 1)
        let expense = try #require(expenses.first)
        #expect(expense.splitMethod == .itemized)
        #expect(expense.total == dollars("104.04"))
        #expect(expense.payments == [Share(People.riley, dollars("104.04"))])
        #expect(expense.allocations.map(\.amount).sum(in: .usd) == dollars("104.04"))
        #expect(expense.groupID == Groups.friday)
        #expect(room.room.state == .finalized)
        #expect(room.engine.state.room(forExpense: expenseID)?.id == room.roomID)
        let snapshot = try #require(room.room.finalSnapshot)
        #expect(snapshot.participants.map(\.total).sum(in: .usd) == dollars("104.04"))
        #expect(snapshot.items.count == 8)
        // It participates in balances like any other expense.
        let plan = room.engine.plan(Groups.friday)
        #expect(plan.confirmedNets.values.map(\.minorUnits).reduce(0, +) == 0)
        #expect(room.engine.state.events.contains { $0.kind == .receiptRoomFinalized(room.roomID, expenseID: expenseID, title: "FERNWOOD SUPPER CLUB") })
        // The room is locked afterwards.
        #expect(error { try room.claim("Tiramisu", .share, as: People.maya) } == .notAllowedInState(.finalized))
    }

    @Test("Finalize requires the final-review state and current readiness")
    func finalizeGuards() throws {
        var room = RoomHarness()
        try room.openDinner()
        #expect(error { try room.run(.finalize(room.roomID, expectedRevision: room.revision)) } == .notAllowedInState(.open))
        try room.claimEverything()
        try room.run(.transition(room.roomID, expectedRevision: room.revision, .requestFinalReview))
        // A dispute raised during final review sends the room back to resolving.
        try room.run(.dispute(room.roomID, expectedRevision: room.revision, .charge(room.charge(.tip).id), note: nil), as: People.priya)
        #expect(room.room.state == .resolving)
    }

    @Test("Host edits clear only the affected item's claims and keep the old values in history")
    func revise() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claimEverything()
        var edited = room.room.receipt
        let tiramisu = try #require(edited.items.firstIndex { $0.name.value == "Tiramisu" })
        let fries = try #require(edited.items.firstIndex { $0.name.value == "Truffle Fries" })
        edited.items[tiramisu].lineTotal.edit(dollars("9.50"), by: People.riley, at: .now)
        edited.items[fries].name.edit("Truffle Fries (large)", by: People.riley, at: .now)
        edited.merchant.edit("Fernwood Supper Club", by: People.riley, at: .now)
        let change = ReceiptRevisionImpact.change(from: room.room.receipt, to: edited)
        #expect(change.financialItemIDs == [edited.items[tiramisu].id])
        try room.run(.reviseReceipt(room.roomID, expectedRevision: room.revision, edited))
        #expect(room.room.claims(for: edited.items[tiramisu].id).isEmpty)
        #expect(room.room.claims(for: edited.items[fries].id).count == 2, "A rename keeps claims")
        #expect(room.room.needsReview == [People.priya])
        guard case .receiptRevised(_, let cleared, let previous) = room.room.history.last?.kind else {
            Issue.record("Expected a revision event")
            return
        }
        #expect(cleared.map(\.memberID) == [People.priya])
        #expect(previous.first?.amount == dollars("8.50"))
        // The receipt no longer adds up, so readiness says so.
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state).contains(.receipt(.totalMismatch(difference: dollars("-1.00")))))
        try room.run(.markReviewed(room.roomID, expectedRevision: room.revision), as: People.priya)
        #expect(room.room.needsReview.isEmpty)
    }

    @Test("Removing a participant clears their claims; members who left the group must be removed")
    func participants() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claim("Tiramisu", as: People.priya)
        try room.run(.setParticipants(room.roomID, expectedRevision: room.revision, participants: [People.riley, People.maya, People.alexMorgan]))
        #expect(room.room.claims(for: room.item("Tiramisu").id).isEmpty)
        guard case .participantsChanged(_, let removed, let cleared) = room.room.history.last?.kind else {
            Issue.record("Expected a participants event")
            return
        }
        #expect(removed == [People.priya])
        #expect(cleared.count == 1)
    }

    @Test("Everything assigned to the payer needs explicit confirmation; negative totals are blocked")
    func payerAndNegativeTotals() throws {
        var room = RoomHarness()
        try room.openDinner()
        for item in room.room.receipt.items {
            try room.run(.setItemSplit(room.roomID, expectedRevision: room.revision, item: item.id, .equal([People.riley])))
        }
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state) == [.onlyPayerOwes])
        try room.run(.setPayerAcceptsFullReceipt(room.roomID, expectedRevision: room.revision, true))
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state).isEmpty)

        // A discount assigned entirely to someone with no items would make their share negative.
        try room.run(.setChargeAllocation(room.roomID, expectedRevision: room.revision, room.charge(.discount).id,
                                          .exact([Share(People.maya, dollars("-4.00"))])))
        #expect(ReceiptRoomReadiness.issues(for: room.room, in: room.engine.state) == [.negativeParticipantTotal(People.maya, dollars("-4.00"))])
    }

    @Test("Cancel keeps opened rooms for history; discard deletes never-opened drafts")
    func cancelAndDiscard() throws {
        var opened = RoomHarness()
        try opened.openDinner()
        try opened.run(.cancel(opened.roomID, expectedRevision: opened.revision))
        #expect(opened.room.state == .cancelled)
        #expect(opened.engine.state.events.last?.kind == .receiptRoomCancelled(opened.roomID, title: "FERNWOOD SUPPER CLUB"))

        var draft = RoomHarness()
        try draft.run(.createDraft(draft.roomID, groupID: nil, pages: [ReceiptFixtures.page()], currency: .usd))
        try draft.run(.discardDraft(draft.roomID))
        #expect(draft.engine.state.room(draft.roomID) == nil)
        #expect(error { try opened.run(.discardDraft(opened.roomID)) } == .notAllowedInState(.cancelled))
    }

    @Test("Every accepted command is audited with the actual simulated actor")
    func audit() throws {
        var room = RoomHarness()
        try room.openDinner()
        try room.claim("Lemonade", as: People.maya)
        let last = try #require(room.room.history.last)
        #expect(last.actorID == People.maya)
        #expect(last.kind == .claimed(room.item("Lemonade").id, .full))
        #expect(last.revision == room.revision)
        #expect(room.room.history.map(\.sequence) == Array(1...room.room.history.count))
    }

    @Test("Finalizing respects pending payments like any other new expense")
    func pendingPaymentConflict() throws {
        var harness = RoomHarness()
        // Riley owes Maya for coffee and reports paying her before the dinner is finalized.
        try harness.engine.run(.addExpense(Expense(
            groupID: Groups.friday, title: "Coffee", date: DemoScenario.fixedReferenceDate, total: dollars("20.00"), category: .food,
            splitMethod: .equal, payments: [Share(People.maya, dollars("20.00"))],
            allocations: [Share(People.maya, dollars("10.00")), Share(People.riley, dollars("10.00"))], createdBy: People.maya
        )))
        let owed = try #require(harness.engine.plan(Groups.friday).payments.first)
        let attempt = try #require(try harness.engine.run(.startPayment(PaymentRequest(
            groupID: Groups.friday, payerID: owed.payerID, recipientID: owed.recipientID, amount: owed.amount, provider: .cash, destinationID: nil
        )), as: owed.payerID).attempt)
        try harness.engine.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)), as: owed.payerID)
        try harness.openDinner()
        try harness.claimEverything()
        try harness.run(.transition(harness.roomID, expectedRevision: harness.revision, .requestFinalReview))
        #expect(throws: LedgerError.rule(.pendingPaymentConflict([attempt.id]))) {
            try harness.run(.finalize(harness.roomID, expectedRevision: harness.revision))
        }
        #expect(harness.room.state == .readyToFinalize, "Nothing was saved")
    }
}
