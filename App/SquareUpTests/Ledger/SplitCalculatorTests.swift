import Foundation
@testable import SquareUp
import Testing

/// A tiny deterministic PRNG so property-style tests are reproducible on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func ids(_ count: Int) -> [MemberID] {
    (0..<count).map { MemberID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))!) }
}

private func usd(_ text: String) -> Money { Money(string: text)! }

@Suite("Split calculator")
struct SplitCalculatorTests {
    @Test("Equal splits with indivisible minor units", arguments: [
        ("100.00", 3, ["33.34", "33.33", "33.33"]),
        ("0.01", 3, ["0.01", "0.00", "0.00"]),
        ("65.00", 3, ["21.67", "21.67", "21.66"]),
        ("10.00", 4, ["2.50", "2.50", "2.50", "2.50"]),
        ("0.05", 2, ["0.03", "0.02"]),
    ])
    func equal(total: String, people: Int, expected: [String]) throws {
        let result = try SplitCalculator.equal(usd(total), among: ids(people))
        #expect(result.shares.map(\.amount) == expected.map(usd))
        #expect(result.total == usd(total))
    }

    @Test("Rounding adjustments name exactly who absorbed the extra cent")
    func roundingAdjustments() throws {
        let people = ids(3)
        let result = try SplitCalculator.equal(usd("100.00"), among: people)
        #expect(result.roundingAdjustments == [people[0]: usd("0.01")])
        let even = try SplitCalculator.equal(usd("99.00"), among: people)
        #expect(even.roundingAdjustments.isEmpty)
    }

    @Test("Property: every allocation sums exactly to its total")
    func sumsExactly() throws {
        var rng = SeededGenerator(state: 42)
        for _ in 0..<500 {
            let units = Int64.random(in: 1...10_000_000, using: &rng)
            let count = Int.random(in: 1...25, using: &rng)
            let total = Money(minorUnits: units, currency: .usd)
            let weights = (0..<count).map { _ in Decimal(Int.random(in: 0...9, using: &rng)) }
            let people = ids(count)

            let equal = try SplitCalculator.equal(total, among: people)
            #expect(equal.total == total)
            let spread = equal.shares.map(\.amount.minorUnits)
            #expect((spread.max() ?? 0) - (spread.min() ?? 0) <= 1, "Equal shares differ by at most one minor unit")

            guard weights.contains(where: { $0 > 0 }) else { continue }
            let weighted = SplitCalculator.allocate(total, weights: Array(zip(people, weights)))
            #expect(weighted.total == total)
            for (share, weight) in zip(weighted.shares, weights) where weight == 0 {
                #expect(share.amount.isZero, "Zero-weight participants pay nothing")
            }
        }
    }

    @Test("Allocation is deterministic for identical input")
    func deterministic() {
        let people = ids(7)
        let weights = people.map { ($0, Decimal(1)) }
        let first = SplitCalculator.allocate(usd("100.00"), weights: weights)
        let second = SplitCalculator.allocate(usd("100.00"), weights: weights)
        #expect(first == second)
    }

    @Test("Exact amounts must reconcile")
    func exact() throws {
        let people = ids(2)
        let ok = try SplitCalculator.exact(usd("50.00"), amounts: [(people[0], usd("30.00")), (people[1], usd("20.00"))])
        #expect(ok.total == usd("50.00"))
        #expect(throws: SplitError.exactAmountsDoNotReconcile(remaining: usd("5.00"))) {
            try SplitCalculator.exact(usd("50.00"), amounts: [(people[0], usd("30.00")), (people[1], usd("15.00"))])
        }
        #expect(throws: SplitError.exactAmountsDoNotReconcile(remaining: -usd("1.00"))) {
            try SplitCalculator.exact(usd("50.00"), amounts: [(people[0], usd("30.00")), (people[1], usd("21.00"))])
        }
    }

    @Test("Percentages must total exactly 100")
    func percentages() throws {
        let people = ids(3)
        let result = try SplitCalculator.percentage(
            usd("90.00"), percentages: [(people[0], 50), (people[1], 25), (people[2], 25)]
        )
        #expect(result.shares.map(\.amount) == ["45.00", "22.50", "22.50"].map(usd))
        let thirds = try SplitCalculator.percentage(
            usd("10.00"), percentages: [(people[0], Decimal(string: "33.34")!), (people[1], Decimal(string: "33.33")!), (people[2], Decimal(string: "33.33")!)]
        )
        #expect(thirds.total == usd("10.00"))
        #expect(throws: SplitError.percentagesDoNotTotal100(total: 99)) {
            try SplitCalculator.percentage(usd("10.00"), percentages: [(people[0], 50), (people[1], 49)])
        }
    }

    @Test("Share-based splits")
    func shares() throws {
        let people = ids(3)
        let result = try SplitCalculator.shares(usd("100.00"), weights: [(people[0], 2), (people[1], 1), (people[2], 1)])
        #expect(result.shares.map(\.amount) == ["50.00", "25.00", "25.00"].map(usd))
        #expect(throws: SplitError.zeroShareWeights) {
            try SplitCalculator.shares(usd("10.00"), weights: [(people[0], 0)])
        }
    }

    @Test("Rejects invalid input")
    func invalid() {
        let person = ids(1)[0]
        #expect(throws: SplitError.nonPositiveTotal) { try SplitCalculator.equal(.zero(), among: [person]) }
        #expect(throws: SplitError.noParticipants) { try SplitCalculator.equal(usd("1.00"), among: []) }
        #expect(throws: SplitError.duplicateParticipant) { try SplitCalculator.equal(usd("1.00"), among: [person, person]) }
        #expect(throws: SplitError.negativeValue) {
            try SplitCalculator.exact(usd("1.00"), amounts: [(person, -usd("1.00"))])
        }
        #expect(throws: SplitError.currencyMismatch) {
            try SplitCalculator.exact(usd("1.00"), amounts: [(person, Money(1, .eur))])
        }
    }

    @Test("Zero-decimal currencies split in whole units")
    func yen() throws {
        let result = try SplitCalculator.equal(Money(1000, .jpy), among: ids(3))
        #expect(result.shares.map(\.amount) == [334, 333, 333].map { Money(Decimal($0), .jpy) })
    }
}
