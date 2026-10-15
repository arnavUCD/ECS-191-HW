import Foundation
@testable import SquareUp
import Testing

/// Milestone 7 §16.4: two Swift clients — two different accounts — against the real local server.
///
/// Opt-in like `LiveServerTests`: `TEST_RUNNER_SQUAREUP_TEST_SERVER=http://127.0.0.1:8093` with a
/// server started with `SQUAREUP_ALLOW_DEV_AUTH=1` (development accounts; see `server/README.md`).
/// Each person has their own Keychain service, so each is a different account to the server.
@MainActor
@Suite("Live shared groups (two accounts)", .enabled(if: LiveServer.configuration != nil), .serialized)
struct LiveSharedGroupTests {
    struct Person {
        let service: SharedGroupsService
        let local: InMemoryLedgerStore
        let account: AccountSession
    }

    func person(_ name: String, local snapshot: LedgerSnapshot? = nil) async throws -> Person {
        let configuration = try #require(LiveServer.configuration)
        let transport = URLSessionTransport()
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "live.group.\(name).\(UUID())"))
        let local = InMemoryLedgerStore(snapshot ?? SampleLedger.newUser())
        let service = SharedGroupsService(configuration: configuration, account: account, transport: transport, cache: SharedGroupCache(root: nil), local: local)
        await service.start()
        if case .needsProfile = service.accountState { try await service.saveProfile(displayName: name) }
        #expect(service.isReady, "\(name) should have a ready account, got \(service.accountState)")
        return Person(service: service, local: local, account: account)
    }

    func nets(_ snapshot: LedgerSnapshot) -> [MemberID: Money] {
        let group = snapshot.groups[0]
        return SettlementPlanner.plan(for: group, expenses: snapshot.expenses(in: group.id), settlements: snapshot.settlements(in: group.id),
                                      attempts: snapshot.attempts(in: group.id)).confirmedNets
    }

    @Test("Create → invite → join → multi-payer expense → conflict → shared receipt → report → confirm → identical balances")
    func primaryProof() async throws {
        let riley = try await person("Riley")
        let maya = try await person("Maya")

        // Riley creates a shared group and invites Maya.
        let groupID = try await riley.service.createGroup(GroupDraft(name: "Coastal Weekend", symbolName: "beach.umbrella.fill"))
        let rileyLedger = try #require(riley.service.ledger(for: groupID))
        let invitation = try await riley.service.createInvitation(for: groupID, seat: nil)
        let code = try #require(invitation.code)
        #expect(invitation.url?.contains("/g/") == true && invitation.appUrl?.hasPrefix("squp://join-group/") == true)

        // Maya previews (safe) and joins, once.
        let preview = try await maya.service.preview(code)
        #expect(preview.groupName == "Coastal Weekend" && preview.inviterName == "Riley" && preview.memberCount == 1 && !preview.alreadyMember)
        let joined = try await maya.service.accept(code, displayName: "Maya")
        #expect(joined == groupID)
        // Accepting again with the same account is answered from the first acceptance (idempotent).
        #expect(try await maya.service.accept(code, displayName: "Maya") == groupID)
        // Another account can't replay it.
        let mallory = try await person("Mallory")
        await #expect(throws: LedgerError.remote(.invitation(.used))) { _ = try await mallory.service.accept(code, displayName: "Mallory") }
        let mayaLedger = try #require(maya.service.ledger(for: groupID))
        try await rileyLedger.refresh()

        let rileyID = try #require(rileyLedger.viewerID)
        let mayaID = try #require(mayaLedger.viewerID)

        // Riley adds a multi-payer expense: Riley paid $60, Maya $30, split equally.
        let total = Money(minorUnits: 9000)
        var dinner = Expense(groupID: groupID, title: "Dinner", date: .now, total: total, category: .food, splitMethod: .equal,
                             payments: [Share(rileyID, Money(minorUnits: 6000)), Share(mayaID, Money(minorUnits: 3000))],
                             allocations: try SplitCalculator.equal(total, among: [rileyID, mayaID]).shares, createdBy: rileyID)
        dinner.splitInput = .equal([rileyID, mayaID])
        try await rileyLedger.perform(.addExpense(dinner), as: nil)

        // Maya sees the identical split and balances.
        try await mayaLedger.refresh()
        let mayaView = try await mayaLedger.snapshot()
        let rileyView = try await rileyLedger.snapshot()
        #expect(mayaView.expense(dinner.id)?.allocations == rileyView.expense(dinner.id)?.allocations)
        #expect(mayaView.expense(dinner.id)?.payments == dinner.payments)
        #expect(nets(mayaView) == nets(rileyView) && nets(mayaView)[rileyID] == Money(minorUnits: 1500))

        // Concurrent edit: another of Riley's devices, based on the old revision, is refused and keeps its draft.
        let secondDevice = SharedGroupLedger(groupID: groupID, account: "riley-second-device", api: try #require(riley.service.api),
                                             cache: SharedGroupCache(root: nil), profile: { nil })
        try await secondDevice.refresh()
        var retitled = try #require(try await rileyLedger.snapshot().expense(dinner.id))
        retitled.title = "Dinner at Driftwood"
        retitled.splitInput = .equal([rileyID, mayaID])
        try await rileyLedger.perform(.updateExpense(retitled), as: nil)
        var stale = try #require(try await secondDevice.snapshot().expense(dinner.id))
        stale.title = "Dinner (edited elsewhere)"
        stale.splitInput = .equal([rileyID, mayaID])
        await #expect(throws: LedgerError.remote(.conflict)) { try await secondDevice.perform(.updateExpense(stale), as: nil) }
        #expect(secondDevice.notice == .expenseChanged(dinner.id))

        // A shared Live Receipt Room with the group's members as seats, finalized and adopted once.
        let roomID = ReceiptRoomID()
        let fries = ReceiptItemID()
        let pizza = ReceiptItemID()
        let rooms = try #require(riley.service.api).client
        let request = PublishRequest(
            roomId: RemoteRoomMapper.id(roomID), hostParticipantId: RemoteRoomMapper.id(rileyID), payerId: RemoteRoomMapper.id(rileyID),
            participants: [PublishRequest.Person(id: RemoteRoomMapper.id(rileyID), displayName: "Riley"),
                           PublishRequest.Person(id: RemoteRoomMapper.id(mayaID), displayName: "Maya")],
            receipt: ReceiptDTO(merchant: "Driftwood Kitchen", date: "2026-10-03", currency: "USD", total: 1950, subtotal: 1950,
                                items: [ItemDTO(id: RemoteRoomMapper.id(fries), name: "Fries", lineTotal: 950, quantity: nil, unitPrice: nil, isRefund: false),
                                        ItemDTO(id: RemoteRoomMapper.id(pizza), name: "Pizza", lineTotal: 1000, quantity: nil, unitPrice: nil, isRefund: false)],
                                charges: []),
            claims: [ClaimDTO(itemId: RemoteRoomMapper.id(fries), participantId: RemoteRoomMapper.id(rileyID), mode: ClaimModeDTO(kind: "full")),
                     ClaimDTO(itemId: RemoteRoomMapper.id(pizza), participantId: RemoteRoomMapper.id(mayaID), mode: ClaimModeDTO(kind: "full"))],
            payerAcceptsFullReceipt: false
        )
        let published = try await rooms.publish(request)
        let ready = try await rooms.command(CommandEnvelope(type: "transition", payload: ["move": "requestFinalReview"], expectedRevision: published.room.revision),
                                            room: RemoteRoomMapper.id(roomID), as: .account)
        _ = try await rooms.command(CommandEnvelope(type: "finalize", payload: [:], expectedRevision: ready.revision), room: RemoteRoomMapper.id(roomID), as: .account)
        let first = try await rileyLedger.adoptRemoteRoom(roomID, guestLinks: [:])
        let second = try await rileyLedger.adoptRemoteRoom(roomID, guestLinks: [:])
        #expect(first == second && first == ExpenseID(roomID.rawValue))
        try await mayaLedger.refresh()
        let withReceipt = try await mayaLedger.snapshot()
        #expect(withReceipt.allExpenses.filter { $0.id == first }.count == 1)
        #expect(withReceipt.room(forExpense: first)?.finalSnapshot?.items.count == 2, "both devices see the frozen item split")

        // Maya pays what she owes: start, open the handoff, report it sent.
        let owed = try #require(LedgerEngine.availableObligation(groupID: groupID, payerID: mayaID, recipientID: rileyID, in: withReceipt))
        let start = try await mayaLedger.perform(.startPayment(PaymentRequest(groupID: groupID, payerID: mayaID, recipientID: rileyID, amount: owed,
                                                                              provider: .cash, destinationID: nil)), as: nil)
        let attempt = try #require(start.attempt)
        try await mayaLedger.perform(.advancePayment(attempt.id, .openHandoff), as: nil)
        try await mayaLedger.perform(.advancePayment(attempt.id, .reportSent(externalReference: nil)), as: nil)
        #expect(try await mayaLedger.snapshot().settlements.isEmpty, "reported sent is not a settlement")

        // Riley sees it waiting and confirms — exactly one settlement, even when confirming twice.
        try await rileyLedger.refresh()
        #expect(try await rileyLedger.snapshot().attempt(attempt.id)?.state == .reportedSent)
        try await rileyLedger.perform(.advancePayment(attempt.id, .confirm), as: nil)
        try await rileyLedger.perform(.advancePayment(attempt.id, .confirm), as: nil)
        try await mayaLedger.refresh()
        let finalMaya = try await mayaLedger.snapshot()
        let finalRiley = try await rileyLedger.snapshot()
        #expect(finalMaya.settlements.count == 1 && finalRiley.settlements.count == 1)
        #expect(nets(finalMaya) == nets(finalRiley))
        #expect(nets(finalMaya)[mayaID] == .zero(.usd) && nets(finalMaya)[rileyID] == .zero(.usd), "both balances become identical again: square")
    }

    @Test("Four accounts: separate invitations → a member joins after an expense → optimized payments → leave → every device agrees")
    func fourPeople() async throws {
        let riley = try await person("Riley")
        let maya = try await person("Maya")
        let sam = try await person("Sam")
        let ana = try await person("Ana")
        let groupID = try await riley.service.createGroup(GroupDraft(name: "Lake House", symbolName: "house.fill"))
        let rileyLedger = try #require(riley.service.ledger(for: groupID))
        #expect(try await rileyLedger.snapshot().groups[0].activeMemberIDs.count == 1, "the creator alone")

        // One invitation per person; each works once.
        var codes: [String] = []
        for _ in 0..<3 { codes.append(try #require(try await riley.service.createInvitation(for: groupID, seat: nil).code)) }
        #expect(Set(codes).count == 3)
        _ = try await maya.service.accept(codes[0], displayName: "Maya")
        _ = try await sam.service.accept(codes[1], displayName: "Sam")
        await #expect(throws: LedgerError.remote(.invitation(.used))) { _ = try await ana.service.accept(codes[0], displayName: "Ana") }
        try await rileyLedger.refresh()
        let rileyID = try #require(rileyLedger.viewerID)
        let mayaLedger = try #require(maya.service.ledger(for: groupID))
        let samLedger = try #require(sam.service.ledger(for: groupID))
        let mayaID = try #require(mayaLedger.viewerID)
        let samID = try #require(samLedger.viewerID)

        // Before Ana joins: $90 dinner, Riley paid, equal among three.
        let total = Money(minorUnits: 9000)
        var dinner = Expense(groupID: groupID, title: "Dinner", date: .now, total: total, category: .food, splitMethod: .equal,
                             payments: [Share(rileyID, total)], allocations: try SplitCalculator.equal(total, among: [rileyID, mayaID, samID]).shares,
                             createdBy: rileyID)
        dinner.splitInput = .equal([rileyID, mayaID, samID])
        try await rileyLedger.perform(.addExpense(dinner), as: nil)

        _ = try await ana.service.accept(codes[2], displayName: "Ana")
        let anaLedger = try #require(ana.service.ledger(for: groupID))
        let anaID = try #require(anaLedger.viewerID)
        let anaView = try await anaLedger.snapshot()
        #expect(anaView.expense(dinner.id)?.participantIDs.contains(anaID) == false, "joining never adds someone to earlier expenses")
        #expect(nets(anaView)[anaID] ?? .zero(.usd) == .zero(.usd))

        // After: Sam pays $40 of groceries shared with Ana (once Sam's iPhone has heard that Ana joined).
        try await samLedger.refresh()
        let groceriesTotal = Money(minorUnits: 4000)
        var groceries = Expense(groupID: groupID, title: "Groceries", date: .now, total: groceriesTotal, category: .groceries, splitMethod: .equal,
                                payments: [Share(samID, groceriesTotal)],
                                allocations: try SplitCalculator.equal(groceriesTotal, among: [samID, anaID]).shares, createdBy: samID)
        groceries.splitInput = .equal([samID, anaID])
        try await samLedger.perform(.addExpense(groceries), as: nil)

        let ledgers = [rileyID: rileyLedger, mayaID: mayaLedger, samID: samLedger, anaID: anaLedger]
        for ledger in ledgers.values { try await ledger.refresh() }
        var views: [LedgerSnapshot] = []
        for ledger in ledgers.values { await views.append(try ledger.snapshot()) }
        #expect(Set(views.map(nets)).count == 1, "every device derives the same balances")
        let group = views[0].groups[0]
        let plan = SettlementPlanner.plan(for: group, expenses: views[0].expenses(in: groupID), settlements: views[0].settlements(in: groupID),
                                          attempts: views[0].attempts(in: groupID))
        #expect(plan.payments.count <= 3 && plan.payments.count <= plan.directPaymentCount)

        // Each suggested payment: the payer reports it, someone unrelated can't confirm it, the recipient does.
        for payment in plan.payments {
            let payer = try #require(ledgers[payment.payerID])
            let recipient = try #require(ledgers[payment.recipientID])
            let start = try await payer.perform(.startPayment(PaymentRequest(groupID: groupID, payerID: payment.payerID, recipientID: payment.recipientID,
                                                                             amount: payment.amount, provider: .cash, destinationID: nil)), as: nil)
            let attempt = try #require(start.attempt)
            try await payer.perform(.advancePayment(attempt.id, .reportSent(externalReference: nil)), as: nil)
            let bystander = try #require(ledgers.first { ![payment.payerID, payment.recipientID].contains($0.key) }?.value)
            try await bystander.refresh()
            await #expect(throws: (any Error).self) { try await bystander.perform(.advancePayment(attempt.id, .confirm), as: nil) }
            try await recipient.refresh()
            try await recipient.perform(.advancePayment(attempt.id, .confirm), as: nil)
        }
        for ledger in ledgers.values { try await ledger.refresh() }
        for ledger in ledgers.values {
            let view = try await ledger.snapshot()
            #expect(nets(view).values.allSatisfy { $0.isZero }, "square on every device")
            #expect(view.settlements.count == plan.payments.count)
        }

        // Ana, settled, leaves; history keeps her name; she no longer has access.
        try await anaLedger.leave()
        try await rileyLedger.refresh()
        #expect(rileyLedger.status(of: anaID) == "removed")
        #expect(try await rileyLedger.snapshot().expense(groceries.id)?.participantIDs.contains(anaID) == true)
        await ana.service.refreshGroups()
        #expect(!ana.service.isShared(groupID) || ana.service.summaries.allSatisfy { $0.group.id != SharedGroupMapper.id(groupID) })
        let invitations = try await riley.service.invitations(for: groupID)
        #expect(invitations.map { $0.state(at: .now) } == [.accepted, .accepted, .accepted])
    }

    @Test("Publishing a local group: once, with its IDs; a seat invitation binds an account without changing history")
    func publication() async throws {
        let sample = SampleLedger.make(referenceDate: .now)
        let publisher = try await person("Riley", local: sample)
        let apartment = SampleLedger.GroupKey.apartment.id
        let review = await publisher.service.publicationReview(of: apartment)
        #expect(review.canPublish, "\(review.blockers)")
        // A lost response: the identical publication is sent twice and applied once.
        let lost = Self.withFreshGroupID(sample, from: apartment)
        let request = SharedGroupsService.publication(lost.id, in: lost.snapshot, publicationID: SharedGroupMapper.id(MemberID()))
        let api = try #require(publisher.service.api)
        let firstTry = try await api.publish(request)
        let retry = try await api.publish(request)
        #expect(firstTry.created && !retry.created && retry.snapshot.revision == firstTry.snapshot.revision)
        #expect(retry.snapshot.expenses.count == firstTry.snapshot.expenses.count, "nothing is duplicated")

        // The app's own path: review, publish, set the local copy aside, open the shared group.
        // A fresh group ID per run: the sample's fixed IDs would collide with an earlier run on the same server.
        let copy = Self.withFreshGroupID(sample, from: apartment)
        let store = InMemoryLedgerStore(copy.snapshot)
        let configuration = try #require(LiveServer.configuration)
        let service = SharedGroupsService(configuration: configuration, account: publisher.account, cache: SharedGroupCache(root: nil), local: store)
        await service.start()
        #expect(try await service.publish(copy.id) == copy.id)
        #expect(try await store.snapshot().group(copy.id) == nil, "the local copy is set aside after the server answered")
        let ledger = try #require(service.ledger(for: copy.id))
        let shared = try await ledger.snapshot()
        let original = try #require(copy.snapshot.group(copy.id))
        #expect(shared.group(copy.id)?.memberIDs == original.memberIDs, "every person keeps their ID")
        #expect(Set(shared.allExpenses.map(\.id)) == Set(copy.snapshot.allExpenses.filter { $0.groupID == copy.id }.map(\.id)))
        #expect(nets(shared) == nets(LedgerSnapshot(currentUserID: copy.snapshot.currentUserID, members: Array(copy.snapshot.members.values),
                                                    groups: [original], expenses: copy.snapshot.expenses(in: copy.id),
                                                    settlements: copy.snapshot.settlements(in: copy.id))))
        // Jordan's seat is waiting; an invitation for that seat binds Jordan's account to it.
        let jordanID = SampleLedger.Person.jordan.id
        #expect(ledger.status(of: jordanID) == "pending")
        let seatInvite = try await service.createInvitation(for: copy.id, seat: jordanID)
        let jordan = try await person("Jordan Brooks")
        _ = try await jordan.service.accept(try #require(seatInvite.code), displayName: "Jordan Brooks")
        let jordanLedger = try #require(jordan.service.ledger(for: copy.id))
        #expect(jordanLedger.viewerID == jordanID, "Jordan's history is Jordan's")
        #expect(await nets(try jordanLedger.snapshot())[jordanID] == nets(shared)[jordanID])
    }

    /// The sample group under a new ID (members and expenses keep their own IDs).
    static func withFreshGroupID(_ snapshot: LedgerSnapshot, from groupID: GroupID) -> (snapshot: LedgerSnapshot, id: GroupID) {
        let id = GroupID()
        let groups = snapshot.groups.map { group -> ExpenseGroup in
            guard group.id == groupID else { return group }
            return ExpenseGroup(id: id, name: group.name, currency: group.currency, symbolName: group.symbolName, memberships: group.memberships,
                                createdAt: group.createdAt, details: group.details, simplifiesDebts: group.simplifiesDebts)
        }
        func moved(_ expense: Expense) -> Expense {
            guard expense.groupID == groupID else { return expense }
            return Expense(id: ExpenseID(), groupID: id, title: expense.title, merchant: expense.merchant, date: expense.date, total: expense.total,
                           category: expense.category, splitMethod: expense.splitMethod, payments: expense.payments, allocations: expense.allocations,
                           note: expense.note, createdBy: expense.createdBy, createdAt: expense.createdAt, revision: expense.revision)
        }
        let settlements = snapshot.settlements.map { settlement -> Settlement in
            guard settlement.groupID == groupID else { return settlement }
            return Settlement(groupID: id, fromID: settlement.fromID, toID: settlement.toID, amount: settlement.amount, date: settlement.date,
                              recordedBy: settlement.recordedBy, provider: settlement.provider)
        }
        return (LedgerSnapshot(currentUserID: snapshot.currentUserID, members: Array(snapshot.members.values), groups: groups,
                               expenses: snapshot.allExpenses.map(moved), settlements: settlements, defaultCurrency: snapshot.defaultCurrency), id)
    }

    @Test("Find a person: look up → invite → no duplicate → accept from Groups → same group and balances; decline; cancel")
    func directInvitations() async throws {
        let riley = try await person("Riley")
        let maya = try await person("Maya")
        let sam = try await person("Sam")
        // A development account's address on this server is `<its ID>@squareup.test`.
        let mayaEmail = try #require(await maya.account.userID) + "@squareup.test"
        let samEmail = try #require(await sam.account.userID) + "@squareup.test"
        let groupID = try await riley.service.createGroup(GroupDraft(name: "Dinner Squad", symbolName: "fork.knife"))
        let rileyLedger = try #require(riley.service.ledger(for: groupID))

        guard case .valid(let typed) = PersonIdentifier.checkEmail("  \(mayaEmail.uppercased()) ") else { Issue.record("not an address"); return }
        let match = try #require(try await riley.service.lookUpPerson(typed, in: groupID))
        #expect(match.displayName == "Maya" && match.status == "available" && match.maskedIdentifier.hasSuffix("@squareup.test"))
        #expect(!match.maskedIdentifier.contains(mayaEmail), "masked")
        #expect(try await riley.service.lookUpPerson(.email("nobody-\(UUID())@squareup.test"), in: groupID) == nil)

        let sent = try await riley.service.invitePerson(typed, to: groupID)
        #expect(sent.status == "pending" && sent.displayName == "Maya")
        await #expect(throws: LedgerError.remote(.refused("They already have an invitation to this group"))) {
            _ = try await riley.service.invitePerson(.email(mayaEmail), to: groupID)
        }
        #expect(try await riley.service.lookUpPerson(.email(mayaEmail), in: groupID)?.status == "invited")

        // Nothing reaches Maya but the invitation itself until she accepts.
        await maya.service.refreshGroups()
        #expect(maya.service.sharedGroupIDs.isEmpty)
        let waiting = try #require(maya.service.receivedInvitations.first)
        #expect(maya.service.receivedInvitations.count == 1 && waiting.groupName == "Dinner Squad" && waiting.inviterName == "Riley")
        #expect(try await maya.service.accept(waiting) == groupID)
        #expect(maya.service.receivedInvitations.isEmpty && maya.service.sharedGroupIDs == [groupID])
        let mayaLedger = try #require(maya.service.ledger(for: groupID))
        try await rileyLedger.refresh()
        #expect(rileyLedger.base?.members.map(\.displayName).sorted() == ["Maya", "Riley"])
        #expect(mayaLedger.base?.members.map(\.displayName).sorted() == ["Maya", "Riley"])

        // An expense on one iPhone reaches the other with identical balances.
        let rileyID = try #require(rileyLedger.viewerID)
        let mayaID = try #require(mayaLedger.viewerID)
        let total = Money(minorUnits: 3000)
        var pizza = Expense(groupID: groupID, title: "Pizza", date: .now, total: total, category: .food, splitMethod: .equal,
                            payments: [Share(rileyID, total)], allocations: try SplitCalculator.equal(total, among: [rileyID, mayaID]).shares,
                            createdBy: rileyID)
        pizza.splitInput = .equal([rileyID, mayaID])
        try await rileyLedger.perform(.addExpense(pizza), as: nil)
        try await mayaLedger.refresh()
        let mayaView = try await mayaLedger.snapshot()
        let rileyView = try await rileyLedger.snapshot()
        #expect(nets(mayaView) == nets(rileyView) && nets(mayaView)[mayaID] == Money(minorUnits: -1500))

        // Any member can invite. Sam declines Maya's invitation; Maya sees it declined.
        let toSam = try await maya.service.invitePerson(.email(samEmail), to: groupID)
        await sam.service.refreshGroups()
        try await sam.service.decline(try #require(sam.service.receivedInvitations.first))
        #expect(sam.service.receivedInvitations.isEmpty && sam.service.sharedGroupIDs.isEmpty)
        #expect(try await maya.service.sentInvitations(in: groupID).first { $0.id == toSam.id }?.status == "declined")
        // Riley invites Sam again (it replaces the declined one: one per person) and cancels it before Sam answers.
        let again = try await riley.service.invitePerson(.email(samEmail), to: groupID)
        #expect(try await riley.service.sentInvitations(in: groupID).map(\.id) == [again.id, sent.id], "the owner sees every one, newest first")
        #expect(try await maya.service.sentInvitations(in: groupID).isEmpty, "a member sees only the ones they sent")
        #expect(try await riley.service.cancelSentInvitation(again.id, in: groupID).status == "cancelled")
        await sam.service.refreshGroups()
        #expect(sam.service.receivedInvitations.isEmpty)
    }
}
