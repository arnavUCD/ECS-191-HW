import Foundation
@testable import SquareUp
import Testing

/// Milestone 7 §16.3: the shared-ledger fixtures in `HW/Shared/parity-fixtures/ledger` run through
/// the Swift `LedgerEngine` here and through the Flask server (`server/tests/test_ledger_parity.py`).
/// After every step both must reach the same outcome (applied, no-op, or the same error code) and the
/// same balances: confirmed and available nets, the settlement plan, settlements, and every expense's
/// revision, tombstone, and allocation. The expectations were recorded from the server.
@Suite("Swift ↔ server ledger parity")
struct LedgerParityTests {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../Shared/parity-fixtures/ledger").standardized

    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    @Test func fixturesArePresent() {
        #expect(Self.names.count >= 3, "Expected the ledger fixtures at \(Self.directory.path())")
    }

    @Test(arguments: names)
    func fixtureMatchesServer(_ name: String) throws {
        let data = try Data(contentsOf: Self.directory.appending(path: "\(name).json"))
        guard case .object(let fixture) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let steps) = fixture["steps"] ?? .null else {
            Issue.record("\(name): malformed fixture")
            return
        }
        var runner = LedgerParityRunner(name: name, fixture: fixture)
        for (index, step) in steps.enumerated() {
            let outcome = runner.run(step)
            let actual: JSONValue = ["outcome": .string(outcome), "balances": runner.balances()]
            #expect(actual == step["expect"], "\(name) step \(index) (\(step["actor"]?.stringValue ?? "") \(step["command"]?.stringValue ?? ""))")
        }
    }
}

/// Replays one fixture through `LedgerEngine` with the same IDs as the server run.
struct LedgerParityRunner {
    let name: String
    let fixture: [String: JSONValue]
    var state: LedgerSnapshot
    let groupID: GroupID
    let keys: [String]
    /// Fixture attempt keys → the IDs the Swift engine generated for them.
    var attempts: [String: PaymentAttemptID] = [:]
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    init(name: String, fixture: [String: JSONValue]) {
        self.name = name
        self.fixture = fixture
        let members = Self.array(fixture["members"]).compactMap(\.stringValue)
        keys = members
        groupID = GroupID(SwiftParityRunner.fixtureUUID(name, "group"))
        let currency = CurrencyCode(fixture["currency"]?.stringValue ?? "USD")
        let people = members.map { Member(id: MemberID(SwiftParityRunner.fixtureUUID(name, $0)), displayName: $0.capitalized) }
        let group = ExpenseGroup(id: groupID, name: name, currency: currency, symbolName: "person.3.fill",
                                 memberships: people.map { Membership(memberID: $0.id) }, createdAt: clock,
                                 simplifiesDebts: fixture["simplify"] != .bool(false))
        state = LedgerSnapshot(currentUserID: people[0].id, members: people, groups: [group], expenses: [], settlements: [],
                               defaultCurrency: currency)
    }

    func member(_ key: String) -> MemberID { MemberID(SwiftParityRunner.fixtureUUID(name, key)) }
    var currency: CurrencyCode { state.groups[0].currency }
    func money(_ units: Int) -> Money { Money(minorUnits: Int64(units), currency: currency) }

    mutating func run(_ step: JSONValue) -> String {
        let actor = member(step["actor"]?.stringValue ?? "")
        let command = step["command"]?.stringValue ?? ""
        do {
            var result: LedgerCommandResult
            switch command {
            case "addExpense", "updateExpense":
                let expense = try expense(step, createdBy: actor)
                result = try perform(command == "addExpense" ? .addExpense(expense) : .updateExpense(expense), actor: actor)
            case "deleteExpense":
                result = try perform(.deleteExpense(ExpenseID(SwiftParityRunner.fixtureUUID(name, step["key"]?.stringValue ?? ""))), actor: actor)
            case "restoreExpense":
                result = try perform(.restoreExpense(ExpenseID(SwiftParityRunner.fixtureUUID(name, step["key"]?.stringValue ?? ""))), actor: actor)
            case "setSimplification":
                result = try perform(.setSimplification(groupID, step["enabled"] == .bool(true)), actor: actor)
            case "startPayment":
                let provider = PaymentProviderKind(rawValue: step["provider"]?.stringValue ?? "cash") ?? .cash
                result = try perform(.startPayment(PaymentRequest(groupID: groupID, payerID: actor, recipientID: member(step["recipient"]?.stringValue ?? ""),
                                                                  amount: money(step["amount"]?.intValue ?? 0), provider: provider, destinationID: nil)),
                                     actor: actor)
                if let attempt = result.attempt, let key = step["attempt"]?.stringValue { attempts[key] = attempt.id }
            case "advancePayment":
                guard let id = attempts[step["attempt"]?.stringValue ?? ""] else { return "attempt_not_found" }
                let action: PaymentAttemptAction = switch step["action"]?.stringValue {
                case "openHandoff": .openHandoff
                case "reportSent": .reportSent(externalReference: nil)
                case "confirm": .confirm
                case "reject": .reject(reason: nil)
                case "dispute": .dispute(reason: nil)
                default: .cancel(.payerCancelled)
                }
                result = try perform(.advancePayment(id, action), actor: actor)
                if step["repeat"] == .bool(true) { result = try perform(.advancePayment(id, action), actor: actor) }
            default:
                return "unknown_command"
            }
            return result.isNoOp ? "noop" : "applied"
        } catch {
            return Self.code(for: error)
        }
    }

    private mutating func perform(_ command: LedgerCommand, actor: MemberID) throws -> LedgerCommandResult {
        clock = clock.addingTimeInterval(60)
        let result = try LedgerEngine.perform(command, on: state, actor: actor, now: clock)
        state = LedgerEngine.apply(result.changes, to: state)
        return result
    }

    /// The expense the server receives for this step: allocations from `SplitCalculator`, with zero
    /// shares kept exactly as the server runner keeps them.
    private func expense(_ step: JSONValue, createdBy: MemberID) throws -> Expense {
        let raw = step["expense"] ?? .null
        let total = money(raw["total"]?.intValue ?? 0)
        guard case .array(let paid) = raw["payments"] ?? .null, case .object(let split) = raw["split"] ?? .null else { throw LedgerError.unavailable }
        let payments = paid.compactMap { pair -> Share? in
            guard case .array(let values) = pair, values.count == 2, let key = values[0].stringValue, let amount = values[1].intValue else { return nil }
            return Share(member(key), money(amount))
        }
        func pairs(_ key: String) -> [(String, JSONValue)] {
            guard case .array(let list) = split[key] ?? .null else { return [] }
            return list.compactMap { pair in
                guard case .array(let values) = pair, values.count == 2, let name = values[0].stringValue else { return nil }
                return (name, values[1])
            }
        }
        let method = SplitMethod(rawValue: split["method"]?.stringValue ?? "") ?? .exact
        let allocations: [Share]
        switch method {
        case .equal:
            guard case .array(let people) = split["participants"] ?? .null else { throw LedgerError.unavailable }
            allocations = try SplitCalculator.equal(total, among: people.compactMap(\.stringValue).map(member)).shares
        case .shares:
            allocations = try SplitCalculator.shares(total, weights: pairs("weights").map { (member($0.0), $0.1.intValue ?? 0) }).shares
        case .percentage:
            allocations = try SplitCalculator.percentage(total, percentages: pairs("percentages").map {
                (member($0.0), Decimal(string: $0.1.stringValue ?? "0", locale: Locale(identifier: "en_US_POSIX")) ?? 0)
            }).shares
        case .exact, .itemized:
            allocations = pairs("amounts").map { Share(member($0.0), money($0.1.intValue ?? 0)) }
        }
        let key = step["key"]?.stringValue ?? ""
        let existing = state.expense(ExpenseID(SwiftParityRunner.fixtureUUID(name, key)))
        return Expense(id: ExpenseID(SwiftParityRunner.fixtureUUID(name, key)), groupID: groupID, title: raw["title"]?.stringValue ?? key,
                       date: existing?.date ?? Date(timeIntervalSince1970: 1_790_000_000), total: total, category: .food, splitMethod: method,
                       payments: payments, allocations: allocations, createdBy: existing?.createdBy ?? createdBy)
    }

    /// The same shape as the server runner's `balances()`, with IDs replaced by fixture keys.
    func balances() -> JSONValue {
        let group = state.groups[0]
        let plan = SettlementPlanner.plan(for: group, expenses: state.expenses(in: groupID), settlements: state.settlements(in: groupID),
                                          attempts: state.attempts(in: groupID))
        let key = Dictionary(uniqueKeysWithValues: keys.map { (member($0), $0) })
        let expenseKeys = Dictionary(Self.array(fixture["steps"]).compactMap { $0["key"]?.stringValue }
            .map { (ExpenseID(SwiftParityRunner.fixtureUUID(name, $0)), $0) }, uniquingKeysWith: { first, _ in first })
        func nets(_ values: [MemberID: Money]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: values.map { (key[$0.key] ?? "?", JSONValue.int(Int($0.value.minorUnits))) }))
        }
        func pair(_ a: String, _ b: String, _ amount: Money) -> JSONValue { [.string(a), .string(b), .int(Int(amount.minorUnits))] }
        let settlements = state.settlements(in: groupID).map { (key[$0.fromID] ?? "?", key[$0.toID] ?? "?", $0.amount) }
            .sorted { ($0.0, $0.1, $0.2.minorUnits) < ($1.0, $1.1, $1.2.minorUnits) }
        let expenses = state.allExpenses.filter { $0.groupID == groupID }.map { expense -> (String, JSONValue) in
            let allocations = expense.allocations.map { (key[$0.memberID] ?? "?", Int($0.amount.minorUnits)) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            let name = expenseKeys[expense.id] ?? "?"
            return (name, [.string(name), .int(expense.revision), .bool(expense.isDeleted),
                           .array(allocations.map { [.string($0.0), .int($0.1)] })])
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return [
            "confirmedNets": nets(plan.confirmedNets),
            "availableNets": nets(plan.availableNets),
            "payments": .array(plan.payments.map { pair(key[$0.payerID] ?? "?", key[$0.recipientID] ?? "?", $0.amount) }),
            "directPaymentCount": .int(plan.directPaymentCount),
            "simplifiedPaymentCount": .int(plan.simplifiedPaymentCount),
            "settlements": .array(settlements.map { pair($0.0, $0.1, $0.2) }),
            "expenses": .array(expenses),
        ]
    }

    static func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let list) = value ?? .null { list } else { [] }
    }

    /// The server's error code for each engine error the fixtures exercise.
    static func code(for error: any Error) -> String {
        switch error as? LedgerError {
        case .rule(.exceedsObligation): "exceeds_obligation"
        case .rule(.noObligation): "no_obligation"
        case .rule(.pendingPaymentConflict): "pending_payment_conflict"
        case .rule(.expenseDeleted): "expense_deleted"
        case .rule(.expenseNotDeleted): "expense_not_deleted"
        case .rule(.cannotPaySelf): "cannot_pay_self"
        case .invalidTransition(.notAuthorized): "forbidden"
        case .invalidTransition(.notAllowed): "not_allowed_in_state"
        case .invalidExpense: "invalid_expense"
        default: "unmapped:\(String(describing: error))"
        }
    }
}
