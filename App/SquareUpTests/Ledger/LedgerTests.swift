import Foundation
@testable import SquareUp
import Testing

private func usd(_ text: String) -> Money { Money(string: text)! }
private let reference = DemoScenario.fixedReferenceDate

/// Builders for small, readable ledgers.
enum Fixture {
    static let a = Member(id: MemberID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!), displayName: "Ana Lima")
    static let b = Member(id: MemberID(UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!), displayName: "Ben Ortiz")
    static let c = Member(id: MemberID(UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!), displayName: "Cy Park")

    static func group(members: [Member] = [a, b, c]) -> ExpenseGroup {
        ExpenseGroup(
            id: GroupID(UUID(uuidString: "99999999-0000-4000-8000-000000000001")!),
            name: "Test", symbolName: "star",
            memberships: members.map { Membership(memberID: $0.id) },
            createdAt: reference
        )
    }

    static func expense(
        in group: ExpenseGroup, total: String, payments: [(Member, String)], allocations: [(Member, String)],
        title: String = "Thing"
    ) -> Expense {
        Expense(
            groupID: group.id, title: title, date: reference, total: usd(total), category: .other, splitMethod: .exact,
            payments: payments.map { Share($0.0.id, usd($0.1)) },
            allocations: allocations.map { Share($0.0.id, usd($0.1)) },
            createdBy: payments.first?.0.id ?? a.id
        )
    }
}

@Suite("Balances")
struct BalanceCalculatorTests {
    @Test("Single payer: others owe the payer their share")
    func singlePayer() {
        let group = Fixture.group()
        let expense = Fixture.expense(in: group, total: "90.00", payments: [(Fixture.a, "90.00")],
                                      allocations: [(Fixture.a, "30.00"), (Fixture.b, "30.00"), (Fixture.c, "30.00")])
        let ledger = BalanceCalculator.ledger(for: group, expenses: [expense], settlements: [])
        #expect(ledger.net(for: Fixture.a.id) == usd("60.00"))
        #expect(ledger.net(for: Fixture.b.id) == -usd("30.00"))
        #expect(ledger.netOwed(from: Fixture.b.id, to: Fixture.a.id) == usd("30.00"))
        #expect(ledger.netOwed(from: Fixture.a.id, to: Fixture.b.id) == -usd("30.00"))
    }

    @Test("Multiple payers: shares are owed in proportion to what each paid")
    func multiplePayers() {
        let group = Fixture.group()
        let expense = Fixture.expense(in: group, total: "100.00",
                                      payments: [(Fixture.a, "75.00"), (Fixture.b, "25.00")],
                                      allocations: [(Fixture.c, "100.00")])
        let ledger = BalanceCalculator.ledger(for: group, expenses: [expense], settlements: [])
        #expect(ledger.netOwed(from: Fixture.c.id, to: Fixture.a.id) == usd("75.00"))
        #expect(ledger.netOwed(from: Fixture.c.id, to: Fixture.b.id) == usd("25.00"))
        #expect(ledger.net(for: Fixture.c.id) == -usd("100.00"))
    }

    @Test("Recorded settlements reduce what is owed and can fully settle a group")
    func settlements() {
        let group = Fixture.group(members: [Fixture.a, Fixture.b])
        let expense = Fixture.expense(in: group, total: "40.00", payments: [(Fixture.a, "40.00")],
                                      allocations: [(Fixture.a, "20.00"), (Fixture.b, "20.00")])
        let partial = Settlement(groupID: group.id, fromID: Fixture.b.id, toID: Fixture.a.id, amount: usd("15.00"),
                                 date: reference, recordedBy: Fixture.b.id)
        var ledger = BalanceCalculator.ledger(for: group, expenses: [expense], settlements: [partial])
        #expect(ledger.netOwed(from: Fixture.b.id, to: Fixture.a.id) == usd("5.00"))
        #expect(!ledger.isSettled)

        let rest = Settlement(groupID: group.id, fromID: Fixture.b.id, toID: Fixture.a.id, amount: usd("5.00"),
                              date: reference, recordedBy: Fixture.a.id)
        ledger = BalanceCalculator.ledger(for: group, expenses: [expense], settlements: [partial, rest])
        #expect(ledger.isSettled)
        #expect(ledger.relationships(for: Fixture.a.id).isEmpty)
    }

    @Test("Property: nets always sum to zero and match paid − owed")
    func zeroSum() throws {
        var rng = SeededGenerator(state: 7)
        let members = [Fixture.a, Fixture.b, Fixture.c]
        let group = Fixture.group()
        for _ in 0..<200 {
            var expenses: [Expense] = []
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let total = Money(minorUnits: Int64.random(in: 1...500_000, using: &rng))
                let payer = members.randomElement(using: &rng)!
                let participants = members.filter { _ in Bool.random(using: &rng) }
                let chosen = participants.isEmpty ? [payer] : participants
                let split = try SplitCalculator.equal(total, among: chosen.map(\.id))
                expenses.append(Expense(groupID: group.id, title: "x", date: reference, total: total, category: .other,
                                        splitMethod: .equal, payments: [Share(payer.id, total)],
                                        allocations: split.shares, createdBy: payer.id))
            }
            let ledger = BalanceCalculator.ledger(for: group, expenses: expenses, settlements: [])
            let nets = members.map { ledger.net(for: $0.id) }
            #expect(nets.sum(in: .usd).isZero)
            for member in members {
                let direct = expenses.map { $0.paid(by: member.id) - $0.owed(by: member.id) }.sum(in: .usd)
                #expect(ledger.net(for: member.id) == direct)
            }
        }
    }
}

@Suite("Expense validation")
struct ExpenseValidatorTests {
    let group = Fixture.group()

    @Test("A reconciled expense passes")
    func valid() throws {
        let expense = Fixture.expense(in: group, total: "10.00", payments: [(Fixture.a, "10.00")],
                                      allocations: [(Fixture.a, "5.00"), (Fixture.b, "5.00")])
        try ExpenseValidator.validate(expense, in: group)
    }

    @Test("Each invariant has a specific error")
    func invariants() {
        let outsider = Member(displayName: "Out Sider")
        let cases: [(Expense, ExpenseValidationError)] = [
            (Fixture.expense(in: group, total: "10.00", payments: [(Fixture.a, "10.00")], allocations: [(Fixture.a, "10.00")], title: "  "), .emptyTitle),
            (Fixture.expense(in: group, total: "10.00", payments: [(Fixture.a, "9.00")], allocations: [(Fixture.a, "10.00")]),
             .paymentsDoNotReconcile(remaining: usd("1.00"))),
            (Fixture.expense(in: group, total: "10.00", payments: [(Fixture.a, "10.00")], allocations: [(Fixture.a, "4.00")]),
             .allocationsDoNotReconcile(remaining: usd("6.00"))),
            (Fixture.expense(in: group, total: "10.00", payments: [], allocations: [(Fixture.a, "10.00")]), .noPayer),
            (Fixture.expense(in: group, total: "10.00", payments: [(outsider, "10.00")], allocations: [(Fixture.a, "10.00")]),
             .participantNotInGroup(outsider.id)),
        ]
        for (expense, error) in cases {
            #expect(throws: error) { try ExpenseValidator.validate(expense, in: group) }
        }
    }
}
