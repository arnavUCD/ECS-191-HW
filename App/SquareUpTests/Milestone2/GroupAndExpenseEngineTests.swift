import Foundation
@testable import SquareUp
import Testing

@Suite("M2.1 Group management")
struct GroupManagementTests {
    @Test("Creating a group adds the creator, new and known members, and an audit event")
    func create() throws {
        var harness = EngineHarness(sample())
        let result = try harness.run(.createGroup(GroupDraft(
            name: "  Weekend Trip ", details: "Big Sur", symbolName: "car.fill", currency: .usd,
            newMembers: [MemberDraft(displayName: "Taylor Kim", handle: "@TKim")],
            existingMemberIDs: [People.maya, People.riley]
        )))
        let id = try #require(result.groupID)
        let group = try #require(harness.state.group(id))
        #expect(group.name == "Weekend Trip")
        #expect(group.details == "Big Sur")
        #expect(group.memberIDs.first == People.riley, "The creator is always a member, first")
        #expect(group.memberIDs.count == 3, "Duplicates of the creator are ignored")
        let taylor = try #require(harness.state.members[result.memberIDs[0]])
        #expect(taylor.displayName == "Taylor Kim")
        #expect(taylor.handle == "tkim", "Handles are normalised without @, lower-cased")
        #expect(harness.state.events(in: id).map(\.kind) == [.groupCreated(name: "Weekend Trip")])
    }

    @Test("Group validation", arguments: [
        (GroupDraft(name: "   "), LedgerError.rule(.groupNameRequired)),
        (GroupDraft(name: String(repeating: "x", count: 61)), LedgerError.rule(.textTooLong)),
        (GroupDraft(name: "Trip", details: String(repeating: "x", count: 141)), LedgerError.rule(.textTooLong)),
        (GroupDraft(name: "Trip", newMembers: [MemberDraft(displayName: " ")]), LedgerError.rule(.memberNameRequired)),
        (GroupDraft(name: "Trip", newMembers: [MemberDraft(displayName: "Ana", handle: "bad handle!")]), LedgerError.rule(.invalidHandle)),
        (GroupDraft(name: "Trip", existingMemberIDs: [MemberID()]), LedgerError.rule(.memberNotFound)),
    ])
    func validation(draft: GroupDraft, error: LedgerError) {
        var harness = EngineHarness(sample())
        #expect(throws: error) { try harness.run(.createGroup(draft)) }
    }

    @Test("Editing records only the changed fields; an unchanged save is a no-op")
    func edit() throws {
        var harness = EngineHarness(sample())
        var draft = GroupDraft(name: "Apartment 4B", symbolName: "house.fill")
        #expect(try harness.run(.updateGroup(Groups.apartment, draft)).isNoOp)
        draft.name = "Apt 4B"
        draft.details = "Russell Blvd"
        try harness.run(.updateGroup(Groups.apartment, draft))
        #expect(harness.state.group(Groups.apartment)?.name == "Apt 4B")
        #expect(harness.state.events(in: Groups.apartment).last?.kind == .groupEdited(fields: [.name, .details]))
    }

    @Test("Currency locks once financial records exist, but not before")
    func currencyLock() throws {
        var harness = EngineHarness(sample())
        #expect(throws: LedgerError.rule(.currencyLocked)) {
            try harness.run(.updateGroup(Groups.apartment, GroupDraft(name: "Apartment 4B", symbolName: "house.fill", currency: .eur)))
        }
        let id = try #require(try harness.run(.createGroup(GroupDraft(name: "Paris"))).groupID)
        try harness.run(.updateGroup(id, GroupDraft(name: "Paris", currency: .eur)))
        #expect(harness.state.group(id)?.currency == .eur)
    }

    @Test("Members with a balance or an open payment can't be removed; settled members can, keeping history")
    func removal() throws {
        var harness = EngineHarness(sample())
        #expect(throws: LedgerError.rule(.memberHasBalance(People.maya, dollars("70.16")))) {
            try harness.run(.removeMember(Groups.apartment, People.maya))
        }
        #expect(throws: LedgerError.rule(.cannotRemoveYourself)) {
            try harness.run(.removeMember(Groups.apartment, People.riley))
        }
        // Friday Dinner Crew is fully settled.
        try harness.run(.removeMember(Groups.friday, People.maya))
        let group = try #require(harness.state.group(Groups.friday))
        #expect(!group.isActiveMember(People.maya))
        #expect(group.memberIDs.contains(People.maya), "History keeps the membership")
        #expect(harness.state.expenses(in: Groups.friday).count == 1, "Past expenses remain")
        #expect(harness.plan(Groups.friday).confirmedNets[People.maya] == .zero())
        // Re-adding reactivates the same membership.
        try harness.run(.addExistingMember(Groups.friday, People.maya))
        #expect(harness.state.group(Groups.friday)?.isActiveMember(People.maya) == true)
        #expect(throws: LedgerError.rule(.memberAlreadyInGroup(People.maya))) {
            try harness.run(.addExistingMember(Groups.friday, People.maya))
        }
    }

    @Test("A member with an open payment can't be removed")
    func removalBlockedByPayment() throws {
        var harness = EngineHarness(sample())
        // Alex Rivera reported paying Riley in the seeded Tahoe data, but also still owes money there.
        #expect(throws: LedgerError.self) { try harness.run(.removeMember(Groups.tahoe, People.alexRivera)) }
    }

    @Test("Removed members can't join new expenses")
    func removedCantJoin() throws {
        var harness = EngineHarness(sample())
        try harness.run(.removeMember(Groups.friday, People.maya))
        let expense = Expense(groupID: Groups.friday, title: "Brunch", date: harness.now, total: dollars("20.00"), category: .food,
                              splitMethod: .equal, payments: [Share(People.riley, dollars("20.00"))],
                              allocations: [Share(People.riley, dollars("10.00")), Share(People.maya, dollars("10.00"))], createdBy: People.riley)
        #expect(throws: LedgerError.rule(.inactiveParticipant(People.maya))) { try harness.run(.addExpense(expense)) }
    }

    @Test("Simplification toggles with an audit event and never changes nets")
    func simplification() throws {
        var harness = EngineHarness(sample())
        let before = harness.plan(Groups.tahoe)
        try harness.run(.setSimplification(Groups.tahoe, false))
        let after = harness.plan(Groups.tahoe)
        #expect(!after.isSimplified)
        #expect(after.confirmedNets == before.confirmedNets)
        #expect(after.availableNets == before.availableNets)
        #expect(after.payments.count == before.directPaymentCount)
        #expect(harness.state.events(in: Groups.tahoe).last?.kind == .simplificationChanged(enabled: false))
        #expect(try harness.run(.setSimplification(Groups.tahoe, false)).isNoOp)
    }
}

@Suite("M2.2 Expense lifecycle")
struct ExpenseLifecycleTests {
    @Test("Editing saves a new revision and keeps the previous one in the audit log")
    func edit() throws {
        var harness = EngineHarness(sample())
        let original = expense("Costco run", in: harness.state)
        var edited = original
        edited.total = dollars("120.00")
        edited.payments = [Share(People.riley, dollars("120.00"))]
        edited.allocations = [Share(People.riley, dollars("40.00")), Share(People.maya, dollars("40.00")), Share(People.jordan, dollars("40.00"))]
        edited.title = "Costco run (bulk)"
        try harness.run(.updateExpense(edited))

        let saved = expense("Costco run (bulk)", in: harness.state)
        #expect(saved.revision == 2)
        #expect(saved.updatedBy == People.riley)
        #expect(saved.createdAt == original.createdAt)
        guard case .expenseEdited(let id, _, let fields, let previous, let revision)? = harness.state.events.last?.kind else {
            Issue.record("Expected an edit event"); return
        }
        #expect(id == original.id)
        #expect(fields == [.title, .amount, .payers, .split])
        #expect(previous.total == dollars("97.35"))
        #expect(previous.revision == 1)
        #expect(revision == 2)
        // Riley lent 64.90 before; now 80.00 → net moves by +15.10.
        #expect(harness.net(People.riley, in: Groups.apartment) == dollars("-14.59"))
    }

    @Test("An unchanged edit is a no-op with no event")
    func noOpEdit() throws {
        var harness = EngineHarness(sample())
        let count = harness.state.events.count
        #expect(try harness.run(.updateExpense(expense("Wi-Fi", in: harness.state))).isNoOp)
        #expect(harness.state.events.count == count)
    }

    @Test("Edits must still reconcile")
    func invalidEdit() {
        var harness = EngineHarness(sample())
        var edited = expense("Wi-Fi", in: harness.state)
        edited.total = dollars("70.00")
        #expect(throws: LedgerError.invalidExpense(.paymentsDoNotReconcile(remaining: dollars("5.00")))) {
            try harness.run(.updateExpense(edited))
        }
    }

    @Test("Soft deletion stops affecting balances, keeps the record, and can be undone")
    func deleteAndRestore() throws {
        var harness = EngineHarness(sample())
        let wifi = expense("Wi-Fi", in: harness.state)
        let before = harness.net(People.riley, in: Groups.apartment)
        try harness.run(.deleteExpense(wifi.id))
        #expect(harness.state.expense(wifi.id)?.isDeleted == true)
        #expect(harness.state.expense(wifi.id)?.deletedBy == People.riley)
        #expect(!harness.state.expenses.contains { $0.id == wifi.id })
        #expect(harness.state.deletedExpenses.map(\.id) == [wifi.id])
        #expect(harness.net(People.riley, in: Groups.apartment) == before + dollars("21.67"))
        guard case .expenseDeleted(_, let snapshot)? = harness.state.events.last?.kind else { Issue.record("Expected delete event"); return }
        #expect(snapshot.total == dollars("65.00"))
        #expect(throws: LedgerError.rule(.expenseDeleted)) { try harness.run(.deleteExpense(wifi.id)) }
        #expect(throws: LedgerError.rule(.expenseDeleted)) { try harness.run(.updateExpense(wifi)) }

        try harness.run(.restoreExpense(wifi.id))
        #expect(harness.net(People.riley, in: Groups.apartment) == before)
        #expect(throws: LedgerError.rule(.expenseNotDeleted)) { try harness.run(.restoreExpense(wifi.id)) }
    }

    @Test("Multiple payers: contributions must add up, and each payer is credited")
    func multiplePayers() throws {
        var harness = EngineHarness(sample())
        let dinner = Expense(groupID: Groups.apartment, title: "Dinner", date: harness.now, total: dollars("90.00"), category: .food,
                             splitMethod: .equal,
                             payments: [Share(People.riley, dollars("60.00")), Share(People.maya, dollars("30.00"))],
                             allocations: [Share(People.riley, dollars("30.00")), Share(People.maya, dollars("30.00")), Share(People.jordan, dollars("30.00"))],
                             createdBy: People.riley)
        let riley = harness.net(People.riley, in: Groups.apartment)
        let jordan = harness.net(People.jordan, in: Groups.apartment)
        try harness.run(.addExpense(dinner))
        #expect(harness.net(People.riley, in: Groups.apartment) == riley + dollars("30.00"))
        #expect(harness.net(People.jordan, in: Groups.apartment) == jordan - dollars("30.00"))

        var bad = dinner
        bad = Expense(groupID: Groups.apartment, title: "Bad", date: harness.now, total: dollars("90.00"), category: .food, splitMethod: .equal,
                      payments: [Share(People.riley, dollars("60.00")), Share(People.maya, dollars("20.00"))],
                      allocations: dinner.allocations, createdBy: People.riley)
        #expect(throws: LedgerError.invalidExpense(.paymentsDoNotReconcile(remaining: dollars("10.00")))) { try harness.run(.addExpense(bad)) }
    }

    @Test("Change summaries name fields and per-person impact")
    func changeSummary() {
        let original = expense("Costco run", in: sample())
        var edited = original
        edited.category = .food
        edited.allocations = [Share(People.riley, dollars("48.68")), Share(People.maya, dollars("48.67"))]
        let summary = ExpenseChangeSummary.make(from: original, to: edited)
        #expect(summary.fields == [.category, .participants])
        let jordan = summary.impacts.first { $0.memberID == People.jordan }
        #expect(jordan?.before == dollars("-32.45"))
        #expect(jordan?.after == .zero())
    }
}
