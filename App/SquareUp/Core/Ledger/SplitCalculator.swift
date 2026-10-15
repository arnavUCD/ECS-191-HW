import Foundation

nonisolated enum SplitError: Error, Equatable, Sendable {
    case noParticipants
    case duplicateParticipant
    case nonPositiveTotal
    case currencyMismatch
    case negativeValue
    /// Exact amounts do not add up. `remaining` is total − assigned (negative = over-assigned).
    case exactAmountsDoNotReconcile(remaining: Money)
    /// Percentages must total exactly 100. `total` is what was entered.
    case percentagesDoNotTotal100(total: Decimal)
    case zeroShareWeights
    case tooManyFractionDigits
}

/// The result of dividing an amount, including who absorbed rounding.
nonisolated struct SplitResult: Equatable, Sendable {
    let shares: [Share]
    /// Members who received one extra (or one fewer) minor unit because the amount was not
    /// evenly divisible. Shown to the user ("Maya pays 1¢ more due to rounding").
    let roundingAdjustments: [MemberID: Money]

    var total: Money? {
        guard let currency = shares.first?.amount.currency else { return nil }
        return shares.map(\.amount).sum(in: currency)
    }
}

/// Deterministic division of money among people.
///
/// ## Rounding policy
/// All math happens in integer minor units. Each participant first receives the floor of their
/// exact quota; leftover units go one at a time to the largest fractional remainders, with ties
/// broken by the order participants were supplied (stable and reproducible on every device).
/// The result always sums exactly to the input.
nonisolated enum SplitCalculator {
    static func equal(_ total: Money, among participants: [MemberID]) throws -> SplitResult {
        try validate(total: total, participants: participants)
        return allocate(total, weights: participants.map { ($0, Decimal(1)) })
    }

    static func exact(_ total: Money, amounts: [(MemberID, Money)]) throws -> SplitResult {
        try validate(total: total, participants: amounts.map(\.0))
        guard amounts.allSatisfy({ $0.1.currency == total.currency }) else { throw SplitError.currencyMismatch }
        guard amounts.allSatisfy({ !$0.1.isNegative }) else { throw SplitError.negativeValue }
        let assigned = amounts.map(\.1).sum(in: total.currency)
        guard assigned == total else {
            throw SplitError.exactAmountsDoNotReconcile(remaining: total - assigned)
        }
        return SplitResult(shares: amounts.map { Share($0.0, $0.1) }, roundingAdjustments: [:])
    }

    /// `percentages` are whole or fractional percents (e.g. 33.34). They must total exactly 100.
    static func percentage(_ total: Money, percentages: [(MemberID, Decimal)]) throws -> SplitResult {
        try validate(total: total, participants: percentages.map(\.0))
        guard percentages.allSatisfy({ $0.1 >= 0 }) else { throw SplitError.negativeValue }
        let sum = percentages.map(\.1).reduce(0, +)
        guard sum == 100 else { throw SplitError.percentagesDoNotTotal100(total: sum) }
        return allocate(total, weights: percentages)
    }

    /// Share-based split ("Maya 2 shares, Alex 1 share").
    static func shares(_ total: Money, weights: [(MemberID, Int)]) throws -> SplitResult {
        try validate(total: total, participants: weights.map(\.0))
        guard weights.allSatisfy({ $0.1 >= 0 }) else { throw SplitError.negativeValue }
        guard weights.contains(where: { $0.1 > 0 }) else { throw SplitError.zeroShareWeights }
        return allocate(total, weights: weights.map { ($0.0, Decimal($0.1)) })
    }

    /// Largest-remainder allocation of `total` proportionally to `weights`.
    static func allocate(_ total: Money, weights: [(MemberID, Decimal)]) -> SplitResult {
        let (units, bumped) = distributeDetailed(minorUnits: total.minorUnits, weights: weights.map(\.1))
        let currency = total.currency
        var shares: [Share] = []
        var adjustments: [MemberID: Money] = [:]
        for (index, (memberID, _)) in weights.enumerated() {
            shares.append(Share(memberID, Money(minorUnits: units[index], currency: currency)))
            if bumped.contains(index) {
                adjustments[memberID] = Money(minorUnits: 1, currency: currency)
            }
        }
        return SplitResult(shares: shares, roundingAdjustments: adjustments)
    }

    /// Integer core of `allocate`. Exposed for property-style tests.
    static func distribute(minorUnits total: Int64, weights: [Decimal]) -> [Int64] {
        distributeDetailed(minorUnits: total, weights: weights).units
    }

    /// Returns each participant's minor units and the indices that received a leftover unit
    /// (their exact quota was fractional and they were rounded *up*).
    ///
    /// Exact integer arithmetic: weights are scaled to integers (percentages carry up to four
    /// fraction digits), each quota is `total × weight ÷ Σweights` as a 128-bit quotient and
    /// remainder, and remainders are compared exactly. This is the same computation as the
    /// server's `money.distribute` (Python `Fraction`), so ties can never break differently.
    static func distributeDetailed(minorUnits total: Int64, weights: [Decimal]) -> (units: [Int64], bumped: Set<Int>) {
        guard !weights.isEmpty else { return ([], []) }
        let integers = scaledToIntegers(weights)
        let weightSum = integers.reduce(Int128(0), +)
        guard weightSum > 0 else { return (weights.map { _ in 0 }, []) }
        var units: [Int64] = []
        var remainders: [(index: Int, remainder: Int128)] = []
        for (index, weight) in integers.enumerated() {
            let numerator = Int128(total) * weight
            let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: weightSum)
            units.append(Int64(quotient))
            if remainder != 0 { remainders.append((index, remainder)) }
        }
        var leftover = total - units.reduce(0, +)
        let order = remainders.sorted { lhs, rhs in
            lhs.remainder == rhs.remainder ? lhs.index < rhs.index : lhs.remainder > rhs.remainder
        }
        var bumped = Set<Int>()
        var cursor = 0
        while leftover > 0 && !order.isEmpty {
            let index = order[cursor % order.count].index
            units[index] += 1
            bumped.insert(index)
            leftover -= 1
            cursor += 1
        }
        return (units, bumped)
    }

    /// Non-negative decimal weights as exact integers with a common power-of-ten scale.
    private static func scaledToIntegers(_ weights: [Decimal]) -> [Int128] {
        let digits = weights.map { max(0, -Int($0.exponent)) }.max() ?? 0
        var scale = Decimal(1)
        for _ in 0..<min(digits, 18) { scale *= 10 }
        return weights.map { weight in
            let scaled = (weight * scale).rounded(scale: 0, mode: .down)
            return Int128(max(0, NSDecimalNumber(decimal: scaled).int64Value))
        }
    }

    private static func validate(total: Money, participants: [MemberID]) throws {
        guard total.isPositive else { throw SplitError.nonPositiveTotal }
        guard !participants.isEmpty else { throw SplitError.noParticipants }
        guard Set(participants).count == participants.count else { throw SplitError.duplicateParticipant }
    }
}
