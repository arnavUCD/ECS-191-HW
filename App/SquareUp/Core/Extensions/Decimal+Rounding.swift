import Foundation

nonisolated extension Decimal {
    /// Rounds to `scale` fractional digits using an explicit rounding mode.
    ///
    /// Square Up uses `.plain` (half away from zero) for user-entered amounts and
    /// never rounds intermediate allocation math; see `SplitCalculator`.
    func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }

    /// The smallest number of fractional digits that represents the value exactly
    /// (12.50 -> 1, 12.505 -> 3, 12 -> 0).
    var significantFractionDigits: Int {
        for digits in 0...38 where rounded(scale: digits) == self {
            return digits
        }
        return 38
    }

    var int64Value: Int64 {
        NSDecimalNumber(decimal: self).int64Value
    }
}
