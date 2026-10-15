"""Exact money arithmetic in integer minor units (mirrors `Money`/`SplitCalculator` in the iOS app).

Every amount on the server is an ``int`` count of minor units (cents for USD) plus a room-level
ISO 4217 currency code. Floating point is never used for money.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction

_ZERO_DIGIT = {
    "BIF",
    "CLP",
    "DJF",
    "GNF",
    "ISK",
    "JPY",
    "KMF",
    "KRW",
    "PYG",
    "RWF",
    "UGX",
    "UYI",
    "VND",
    "VUV",
    "XAF",
    "XOF",
    "XPF",
}
_THREE_DIGIT = {"BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"}

#: Largest absolute amount accepted anywhere in the API (1 billion major units in cents).
MAX_ABS_MINOR_UNITS = 100_000_000_000


def minor_unit_digits(currency: str) -> int:
    """ISO 4217 exponent; matches `CurrencyCode.minorUnitDigits`."""
    code = currency.upper()
    if code in _ZERO_DIGIT:
        return 0
    if code in _THREE_DIGIT:
        return 3
    return 2


def is_valid_currency(code: object) -> bool:
    return isinstance(code, str) and len(code) == 3 and code.isascii() and code.isalpha() and code.isupper()


@dataclass(frozen=True)
class Distribution:
    units: list[int]
    #: Indices that received one leftover unit (their quota was rounded up).
    bumped: set[int]


def distribute(total: int, weights: list[int]) -> Distribution:
    """Largest-remainder division of a non-negative ``total`` by integer ``weights``.

    Port of ``SplitCalculator.distributeDetailed``: floor every exact quota, then hand the
    leftover units one at a time to the largest fractional remainders, ties broken by input order.
    The result always sums exactly to ``total``.
    """
    if not weights:
        return Distribution([], set())
    weight_sum = sum(weights)
    if weight_sum <= 0:
        return Distribution([0 for _ in weights], set())
    units: list[int] = []
    remainders: list[tuple[int, Fraction]] = []
    for index, weight in enumerate(weights):
        quota = Fraction(total * weight, weight_sum)
        floor = quota.numerator // quota.denominator
        units.append(floor)
        if quota != floor:
            remainders.append((index, quota - floor))
    leftover = total - sum(units)
    order = sorted(remainders, key=lambda pair: (-pair[1], pair[0]))
    bumped: set[int] = set()
    cursor = 0
    while leftover > 0 and order:
        index = order[cursor % len(order)][0]
        units[index] += 1
        bumped.add(index)
        leftover -= 1
        cursor += 1
    return Distribution(units, bumped)


def divide_signed(amount: int, weights: list[int]) -> tuple[list[int], set[int]]:
    """Divide a signed amount by magnitude and restore the sign (refunds, discounts)."""
    sign = -1 if amount < 0 else 1
    result = distribute(abs(amount), weights)
    return [unit * sign for unit in result.units], result.bumped
