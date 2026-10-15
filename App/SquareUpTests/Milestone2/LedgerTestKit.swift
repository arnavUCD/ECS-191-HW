import Foundation
@testable import SquareUp

/// Deterministic identifiers so engine results are reproducible and stores can be compared.
final class SequentialIDs {
    private var next: Int

    init(start: Int = 0) {
        next = start
    }

    func make() -> UUID {
        next += 1
        return UUID(uuidString: String(format: "EEEEEEEE-0000-4000-8000-%012d", next))!
    }
}

/// Drives `LedgerEngine` directly against snapshots (pure, no store).
struct EngineHarness {
    var state: LedgerSnapshot
    var now = DemoScenario.fixedReferenceDate
    let ids = SequentialIDs(start: 90_000)

    init(_ state: LedgerSnapshot) {
        self.state = state
    }

    @discardableResult
    mutating func run(_ command: LedgerCommand, as actor: MemberID? = nil) throws(LedgerError) -> LedgerCommandResult {
        let result = try LedgerEngine.perform(command, on: state, actor: actor ?? state.currentUserID, now: now, makeID: ids.make)
        state = LedgerEngine.apply(result.changes, to: state)
        return result
    }

    func plan(_ groupID: GroupID) -> SettlementPlan {
        let group = state.group(groupID)!
        return SettlementPlanner.plan(for: group, expenses: state.expenses(in: groupID),
                                      settlements: state.settlements(in: groupID), attempts: state.attempts(in: groupID))
    }

    func net(_ member: MemberID, in groupID: GroupID) -> Money {
        plan(groupID).confirmedNet(for: member)
    }
}

enum People {
    static let riley = SampleLedger.Person.riley.id
    static let maya = SampleLedger.Person.maya.id
    static let jordan = SampleLedger.Person.jordan.id
    static let alexMorgan = SampleLedger.Person.alexMorgan.id
    static let alexRivera = SampleLedger.Person.alexRivera.id
    static let sam = SampleLedger.Person.sam.id
    static let lena = SampleLedger.Person.lena.id
    static let priya = SampleLedger.Person.priya.id
}

enum Groups {
    static let apartment = SampleLedger.GroupKey.apartment.id
    static let tahoe = SampleLedger.GroupKey.tahoe.id
    static let friday = SampleLedger.GroupKey.friday.id
}

func dollars(_ text: String) -> Money { Money(string: text)! }

func sample() -> LedgerSnapshot { SampleLedger.make(referenceDate: DemoScenario.fixedReferenceDate) }

func expense(_ title: String, in snapshot: LedgerSnapshot) -> Expense {
    snapshot.allExpenses.first { $0.title == title }!
}

func destination(of member: MemberID, _ provider: PaymentProviderKind, in snapshot: LedgerSnapshot) -> PaymentDestination? {
    snapshot.paymentDestinations.first { $0.ownerID == member && $0.provider == provider }
}
