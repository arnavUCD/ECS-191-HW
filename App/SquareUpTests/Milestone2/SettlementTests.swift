import Foundation
@testable import SquareUp
import Testing

@Suite("M2.3 Settlement plan")
struct SettlementPlannerTests {
    @Test("Apartment: Riley pays Maya $29.69 and Jordan pays Maya $40.47")
    func apartmentPlan() {
        let harness = EngineHarness(sample())
        let plan = harness.plan(Groups.apartment)
        #expect(plan.payments.map { [$0.payerID, $0.recipientID] } == [[People.riley, People.maya], [People.jordan, People.maya]])
        #expect(plan.payments.map(\.amount) == [dollars("29.69"), dollars("40.47")])
        #expect(PlanLanguage.sentence(for: plan.payments[0], members: harness.state.members, currentUserID: People.riley) == "You pay Maya $29.69.")
        #expect(PlanLanguage.sentence(for: plan.payments[1], members: harness.state.members, currentUserID: People.riley) == "Jordan pays Maya $40.47.")
    }

    @Test("Tahoe: simplification reduces transfers and the reported payment is held out")
    func tahoePlan() {
        let harness = EngineHarness(sample())
        let plan = harness.plan(Groups.tahoe)
        #expect(plan.isSimplified)
        #expect(plan.pending.count == 1)
        #expect(plan.availableNet(for: People.alexRivera).isZero, "Alex R.'s reported $417.10 covers what they owed")
        #expect(plan.confirmedNet(for: People.alexRivera) == dollars("-417.10"), "…but isn't confirmed")
        #expect(plan.payment(from: People.alexRivera, to: People.riley) == nil, "No duplicate suggestion")
        #expect(plan.simplifiedPaymentCount < plan.directPaymentCount)
        #expect(PlanLanguage.countSummary(plan) == "\(plan.simplifiedPaymentCount) payments instead of \(plan.directPaymentCount).")
    }

    @Test("Property: simplification preserves every net, moves exactly what is owed, and is deterministic")
    func property() {
        var rng = SeededGenerator(state: 2_026)
        let members = (1...6).map { MemberID(UUID(uuidString: String(format: "DDDDDDDD-0000-4000-8000-%012d", $0))!) }
        for _ in 0..<300 {
            var nets: [MemberID: Int64] = [:]
            var balance: Int64 = 0
            for member in members.dropLast() {
                let value = Int64.random(in: -50_000...50_000, using: &rng)
                nets[member] = value
                balance += value
            }
            nets[members.last!] = -balance
            let transfers = SettlementPlanner.simplifiedTransfers(nets: nets, order: members)
            #expect(transfers.count <= max(0, nets.values.filter { $0 != 0 }.count - 1))
            var check = nets
            for transfer in transfers {
                #expect(transfer.units > 0)
                check[transfer.from, default: 0] += transfer.units
                check[transfer.to, default: 0] -= transfer.units
            }
            #expect(check.values.allSatisfy { $0 == 0 }, "Every net is exactly satisfied")
            #expect(SettlementPlanner.simplifiedTransfers(nets: nets, order: members) == transfers, "Deterministic")
        }
    }

    @Test("Exact matches pair up before greedy matching, with stable tie-breaking")
    func exactMatchesAndTies() {
        let ids = (1...4).map { MemberID(UUID(uuidString: String(format: "CCCCCCCC-0000-4000-8000-%012d", $0))!) }
        // a owes 30, b owes 10; c is owed 10, d is owed 30 → two exact payments.
        let nets: [MemberID: Int64] = [ids[0]: -3000, ids[1]: -1000, ids[2]: 1000, ids[3]: 3000]
        let transfers = SettlementPlanner.simplifiedTransfers(nets: nets, order: ids)
        #expect(transfers == [
            .init(from: ids[0], to: ids[3], units: 3000),
            .init(from: ids[1], to: ids[2], units: 1000),
        ])
        // Equal creditors: the earlier member in membership order is chosen first.
        let tied: [MemberID: Int64] = [ids[0]: -2000, ids[1]: 1000, ids[2]: 1000, ids[3]: 0]
        #expect(SettlementPlanner.simplifiedTransfers(nets: tied, order: ids).first == .init(from: ids[0], to: ids[1], units: 1000))
    }

    @Test("Turning simplification off shows pairwise debts")
    func directPlan() throws {
        var harness = EngineHarness(sample())
        try harness.run(.setSimplification(Groups.tahoe, false))
        let plan = harness.plan(Groups.tahoe)
        #expect(plan.payments.count == plan.directPaymentCount)
        #expect(PlanLanguage.countSummary(plan).hasPrefix("\(plan.directPaymentCount) payments."))
    }

    @Test("A settled group says so")
    func settled() {
        let harness = EngineHarness(sample())
        let plan = harness.plan(Groups.friday)
        #expect(plan.isSettled)
        #expect(PlanLanguage.countSummary(plan) == "Everyone is square.")
    }
}

@Suite("M2.6 Payment attempt state machine")
struct PaymentAttemptMachineTests {
    static let payer = MemberID(UUID(uuidString: "AAAAAAAA-1111-4000-8000-000000000001")!)
    static let recipient = MemberID(UUID(uuidString: "BBBBBBBB-1111-4000-8000-000000000002")!)
    static let stranger = MemberID(UUID(uuidString: "CCCCCCCC-1111-4000-8000-000000000003")!)

    static func attempt(in state: PaymentAttemptState) -> PaymentAttempt {
        PaymentAttempt(
            id: PaymentAttemptID(UUID(uuidString: "FFFFFFFF-1111-4000-8000-000000000009")!), groupID: GroupID(),
            payerID: payer, recipientID: recipient, destinationID: nil, provider: .venmo, amount: dollars("10.00"),
            memo: "m", state: state, history: [PaymentAttemptTransition(state: state, actorID: payer, date: .distantPast)]
        )
    }

    static let actions: [(String, PaymentAttemptAction, MemberID)] = [
        ("openHandoff", .openHandoff, payer),
        ("reportSent", .reportSent(externalReference: nil), payer),
        ("confirm", .confirm, recipient),
        ("reject", .reject(reason: nil), recipient),
        ("dispute", .dispute(reason: nil), recipient),
        ("cancel", .cancel(.payerCancelled), payer),
    ]

    /// Expected result for (state, action): the next state, "same" for an idempotent repeat, or nil if forbidden.
    static let table: [PaymentAttemptState: [String: PaymentAttemptState?]] = [
        .methodSelected: ["openHandoff": .handoffOpened, "reportSent": .reportedSent, "confirm": nil, "reject": nil, "dispute": nil, "cancel": .cancelled],
        .handoffOpened: ["openHandoff": .handoffOpened, "reportSent": .reportedSent, "confirm": nil, "reject": nil, "dispute": nil, "cancel": .cancelled],
        .reportedSent: ["openHandoff": nil, "reportSent": .reportedSent, "confirm": .confirmed, "reject": .rejected, "dispute": .disputed, "cancel": .cancelled],
        .disputed: ["openHandoff": nil, "reportSent": nil, "confirm": .confirmed, "reject": .rejected, "dispute": .disputed, "cancel": nil],
        .confirmed: ["openHandoff": nil, "reportSent": nil, "confirm": .confirmed, "reject": nil, "dispute": nil, "cancel": nil],
        .rejected: ["openHandoff": nil, "reportSent": nil, "confirm": nil, "reject": .rejected, "dispute": nil, "cancel": nil],
        .cancelled: ["openHandoff": nil, "reportSent": nil, "confirm": nil, "reject": nil, "dispute": nil, "cancel": .cancelled],
    ]

    @Test("Every allowed and forbidden transition", arguments: PaymentAttemptState.allCases)
    func transitions(from state: PaymentAttemptState) {
        for (name, action, actor) in Self.actions {
            let expected = Self.table[state]![name]!
            let start = Self.attempt(in: state)
            do {
                let outcome = try PaymentAttemptMachine.apply(action, to: start, actor: actor, at: .now)
                #expect(expected != nil, "\(name) should be forbidden from \(state)")
                #expect(outcome.attempt.state == expected)
                #expect(outcome.didChange == (expected != state), "Repeats are idempotent no-ops")
                if outcome.didChange {
                    #expect(outcome.attempt.history.last == PaymentAttemptTransition(state: expected!, actorID: actor, date: outcome.attempt.history.last!.date,
                                                                                     note: outcome.attempt.history.last!.note))
                }
            } catch {
                #expect(expected == nil, "\(name) should be allowed from \(state): \(error)")
            }
        }
    }

    @Test("Only the payer reports or cancels; only the recipient confirms or rejects")
    func authorization() {
        let reported = Self.attempt(in: .reportedSent)
        #expect(throws: PaymentTransitionError.notAuthorized(action: "confirm")) {
            try PaymentAttemptMachine.apply(.confirm, to: reported, actor: Self.payer, at: .now)
        }
        #expect(throws: PaymentTransitionError.notAuthorized(action: "reject")) {
            try PaymentAttemptMachine.apply(.reject(reason: nil), to: reported, actor: Self.stranger, at: .now)
        }
        #expect(throws: PaymentTransitionError.notAuthorized(action: "cancel")) {
            try PaymentAttemptMachine.apply(.cancel(.payerCancelled), to: reported, actor: Self.recipient, at: .now)
        }
        #expect(throws: PaymentTransitionError.notAuthorized(action: "reportSent")) {
            try PaymentAttemptMachine.apply(.reportSent(externalReference: nil), to: Self.attempt(in: .methodSelected), actor: Self.recipient, at: .now)
        }
        // Either party may dispute.
        #expect((try? PaymentAttemptMachine.apply(.dispute(reason: nil), to: reported, actor: Self.payer, at: .now)) != nil)
    }

    @Test("Reported references are trimmed; blank becomes nil")
    func reference() throws {
        let draft = Self.attempt(in: .handoffOpened)
        #expect(try PaymentAttemptMachine.apply(.reportSent(externalReference: "  1234 "), to: draft, actor: Self.payer, at: .now)
            .attempt.externalReference == "1234")
        #expect(try PaymentAttemptMachine.apply(.reportSent(externalReference: "   "), to: draft, actor: Self.payer, at: .now)
            .attempt.externalReference == nil)
    }
}

@Suite("M2.6 Payment lifecycle in the ledger")
struct PaymentLifecycleTests {
    private func start(_ harness: inout EngineHarness, amount: String = "29.69", provider: PaymentProviderKind = .appleCash) throws -> PaymentAttempt {
        let destination = destination(of: People.maya, provider, in: harness.state)
        return try #require(try harness.run(.startPayment(PaymentRequest(
            groupID: Groups.apartment, payerID: People.riley, recipientID: People.maya, amount: dollars(amount),
            provider: provider, destinationID: destination?.id
        ))).attempt)
    }

    @Test("Starting, opening, and reporting: no balance effect until confirmation; reported amount leaves the plan")
    func reportReserves() throws {
        var harness = EngineHarness(sample())
        let netBefore = harness.net(People.riley, in: Groups.apartment)
        let attempt = try start(&harness)
        #expect(attempt.state == .methodSelected)
        #expect(attempt.memo.hasPrefix("Square Up · Apartment 4B · SU-"))
        #expect(harness.plan(Groups.apartment).payment(from: People.riley, to: People.maya) != nil, "A draft reserves nothing")

        try harness.run(.advancePayment(attempt.id, .openHandoff))
        #expect(harness.plan(Groups.apartment).payment(from: People.riley, to: People.maya) != nil, "Opening an app reserves nothing")

        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        let plan = harness.plan(Groups.apartment)
        #expect(plan.payment(from: People.riley, to: People.maya) == nil, "Reported payment is not suggested again")
        #expect(plan.pending.map(\.id) == [attempt.id])
        #expect(harness.net(People.riley, in: Groups.apartment) == netBefore, "Confirmed ledger unchanged")
        #expect(harness.state.settlements.allSatisfy { $0.attemptID != attempt.id })
        // Reporting twice is a no-op.
        #expect(try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil))).isNoOp)
    }

    @Test("Recipient confirmation creates exactly one settlement, idempotently")
    func confirmOnce() throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        let first = try harness.run(.advancePayment(attempt.id, .confirm), as: People.maya)
        let settlement = try #require(first.settlement)
        #expect(settlement.id == SettlementID(attempt.id.rawValue))
        #expect(settlement.provider == .appleCash)
        #expect(settlement.confirmedBy == People.maya)
        #expect(settlement.amount == dollars("29.69"))

        let second = try harness.run(.advancePayment(attempt.id, .confirm), as: People.maya)
        #expect(second.isNoOp)
        #expect(harness.state.settlements.filter { $0.attemptID == attempt.id }.count == 1)
        #expect(harness.net(People.riley, in: Groups.apartment).isZero)
        #expect(harness.plan(Groups.apartment).pending.isEmpty)
        #expect(harness.state.attempt(attempt.id)?.settlementID == settlement.id)
        guard case .paymentConfirmed(_, let id)? = harness.state.events.last?.kind else { Issue.record("Expected confirm event"); return }
        #expect(id == settlement.id)
    }

    @Test("Payer can't confirm their own payment")
    func payerCantConfirm() throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        #expect(throws: LedgerError.invalidTransition(.notAuthorized(action: "confirm"))) {
            try harness.run(.advancePayment(attempt.id, .confirm))
        }
    }

    @Test("Rejection and cancellation restore the obligation", arguments: ["reject", "cancel"])
    func restore(how: String) throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        if how == "reject" {
            try harness.run(.advancePayment(attempt.id, .reject(reason: nil)), as: People.maya)
        } else {
            try harness.run(.advancePayment(attempt.id, .cancel(.payerCancelled)))
        }
        #expect(harness.plan(Groups.apartment).payment(from: People.riley, to: People.maya)?.amount == dollars("29.69"))
        #expect(harness.plan(Groups.apartment).pending.isEmpty)
        #expect(harness.state.settlements.allSatisfy { $0.attemptID != attempt.id })
    }

    @Test("Disputed payments stay reserved, then resolve by confirm or reject")
    func dispute() throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        try harness.run(.advancePayment(attempt.id, .dispute(reason: "Not in my account yet")), as: People.maya)
        #expect(harness.plan(Groups.apartment).pending.map(\.state) == [.disputed])
        #expect(harness.plan(Groups.apartment).payment(from: People.riley, to: People.maya) == nil)
        try harness.run(.advancePayment(attempt.id, .confirm), as: People.maya)
        #expect(harness.net(People.riley, in: Groups.apartment).isZero)
    }

    @Test("A second handoff for the same obligation supersedes the first draft")
    func supersede() throws {
        var harness = EngineHarness(sample())
        let first = try start(&harness, provider: .appleCash)
        let second = try start(&harness, provider: .paypal)
        #expect(harness.state.attempt(first.id)?.state == .cancelled)
        #expect(harness.state.attempt(first.id)?.history.last?.note == PaymentCancelReason.superseded.rawValue)
        #expect(harness.state.attempt(second.id)?.state == .methodSelected)
    }

    @Test("Start validation", arguments: [
        ("0.00", LedgerError.rule(.nonPositiveAmount)),
        ("30.00", LedgerError.rule(.exceedsObligation(dollars("29.69")))),
    ])
    func startValidation(amount: String, error: LedgerError) {
        var harness = EngineHarness(sample())
        #expect(throws: error) { try start(&harness, amount: amount) }
    }

    @Test("No obligation, self-payment, other currency, and foreign or disabled destinations are rejected")
    func startGuards() throws {
        var harness = EngineHarness(sample())
        func request(_ payer: MemberID, _ recipient: MemberID, _ amount: Money, _ destination: PaymentDestinationID? = nil,
                     _ provider: PaymentProviderKind = .other) -> LedgerCommand {
            .startPayment(PaymentRequest(groupID: Groups.apartment, payerID: payer, recipientID: recipient, amount: amount,
                                         provider: provider, destinationID: destination))
        }
        #expect(throws: LedgerError.rule(.noObligation)) { try harness.run(request(People.riley, People.jordan, dollars("1.00"))) }
        #expect(throws: LedgerError.rule(.cannotPaySelf)) { try harness.run(request(People.riley, People.riley, dollars("1.00"))) }
        #expect(throws: LedgerError.rule(.currencyMismatch)) { try harness.run(request(People.riley, People.maya, Money(1, .eur))) }
        #expect(throws: LedgerError.invalidTransition(.notAuthorized(action: "startPayment"))) {
            try harness.run(request(People.jordan, People.maya, dollars("1.00")))
        }
        let rileysOwn = try #require(destination(of: People.riley, .paypal, in: harness.state))
        #expect(throws: LedgerError.rule(.destinationUnavailable)) {
            try harness.run(request(People.riley, People.maya, dollars("1.00"), rileysOwn.id, .paypal))
        }
        var disabled = try #require(destination(of: People.maya, .zelle, in: harness.state))
        disabled.isEnabled = false
        try harness.run(.saveDestination(disabled), as: People.maya)
        #expect(throws: LedgerError.rule(.destinationUnavailable)) {
            try harness.run(request(People.riley, People.maya, dollars("1.00"), disabled.id, .zelle))
        }
    }

    @Test("Reporting re-checks the obligation: a stale draft can't over-reserve")
    func staleDraft() throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        // Maya records receiving the money directly in the meantime; nothing is owed now.
        try harness.run(.recordSettlement(Settlement(groupID: Groups.apartment, fromID: People.riley, toID: People.maya,
                                                     amount: dollars("29.69"), date: harness.now, recordedBy: People.maya)))
        #expect(throws: LedgerError.rule(.noObligation)) {
            try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        }
        try harness.run(.advancePayment(attempt.id, .cancel(.payerCancelled)))
    }

    @Test("Edits and deletions that change a pending payer's or recipient's balance are blocked")
    func pendingConflicts() throws {
        var harness = EngineHarness(sample())
        let attempt = try start(&harness)
        try harness.run(.advancePayment(attempt.id, .reportSent(externalReference: nil)))
        let costco = expense("Costco run", in: harness.state)
        #expect(throws: LedgerError.rule(.pendingPaymentConflict([attempt.id]))) { try harness.run(.deleteExpense(costco.id)) }
        var edited = costco
        edited.title = "Costco"
        try harness.run(.updateExpense(edited)) // title-only edit changes no balance: allowed
        // A group with no pending payments: allowed.
        try harness.run(.deleteExpense(expense("Nopa dinner", in: harness.state).id))
        // Tahoe has Alex R.'s pending payment to Riley, so changing Riley's balance there is blocked too.
        #expect(throws: LedgerError.self) { try harness.run(.deleteExpense(expense("Gas & snacks", in: harness.state).id)) }
        // Resolve, then the change goes through.
        try harness.run(.advancePayment(attempt.id, .confirm), as: People.maya)
        try harness.run(.deleteExpense(costco.id))
    }

    @Test("Seeded recipient confirmation works as the current user")
    func seededConfirmation() throws {
        var harness = EngineHarness(sample())
        let attempt = try #require(harness.state.paymentAttempts.first { $0.state == .reportedSent })
        #expect(attempt.recipientID == People.riley)
        try harness.run(.advancePayment(attempt.id, .confirm))
        #expect(harness.plan(Groups.tahoe).confirmedNet(for: People.alexRivera).isZero)
    }
}
