"""The parity rule's arithmetic (docs/evaluation-protocol.md, "Primary harm
metrics and the parity rule"; spec EVAL04). Standard library only.

Harm difference is candidate harm minus reference harm, paired. A candidate
passes a comparison only when the one-sided upper confidence bound of that
difference is at most zero. Each bound is at 97.5 % one-sided: 95 % overall,
Bonferroni over the two candidates.

- EVAL02 (fidelity): Tango's score interval for a difference of paired
  proportions, one item per original.
- EVAL03 (privacy): the paired difference of per-writer success rates, its
  bound found by inverting an exact sign-flip test over writers.
- The EVAL02 sample size: the smallest holdout at which a candidate with the
  development rates passes with probability at least 80 %, computed exactly
  over the paired outcomes.
"""

import math
from fractions import Fraction
from statistics import NormalDist

ALPHA = Fraction(1, 40)  # 2.5 % one-sided per bound: 5 % overall over two candidates
POWER = 0.8


# EVAL02: Tango's score interval.


def _tango_z(b: int, c: int, n: int, delta: float) -> float:
    """Tango's score statistic for H0: p_b - p_c = delta, where b items fail
    for the candidate only and c for the reference only, out of n. The
    reference-only rate is replaced by its maximum-likelihood value under H0,
    the larger root of 2n q^2 - B q - C = 0."""
    numerator = b - c - n * delta
    if numerator == 0:
        return 0.0
    big_b = (b + c) + delta * (b - c - 2 * n)
    big_c = c * delta * (1 - delta)
    q = (big_b + math.sqrt(max(big_b * big_b + 8 * n * big_c, 0.0))) / (4 * n)
    variance = n * (2 * q + delta - delta * delta)
    if variance <= 0:
        return math.copysign(math.inf, numerator)
    return numerator / math.sqrt(variance)


def tango_upper(b: int, c: int, n: int, alpha: Fraction = ALPHA) -> float:
    """The one-sided upper confidence bound of p_b - p_c: the largest delta
    the score test at level alpha does not reject. Positive when b == c,
    including when no paired failure is seen at all (it is then
    z^2 / (n + z^2))."""
    if not (n > 0 and 0 <= b and 0 <= c and b + c <= n):
        raise ValueError(f"impossible counts b={b} c={c} n={n}")
    z = NormalDist().inv_cdf(1 - float(alpha))
    low, high = (b - c) / n, 1.0
    if low >= 1.0:
        return 1.0
    # The statistic falls as delta rises; find where it crosses -z.
    for _ in range(80):
        mid = (low + high) / 2
        if _tango_z(b, c, n, mid) >= -z:
            low = mid
        else:
            high = mid
    return low


# EVAL03: the exact sign-flip bound over writers.


def sign_flip_upper(differences: list[Fraction], alpha: Fraction = ALPHA) -> Fraction | None:
    """The one-sided upper confidence bound for the centre of the per-writer
    differences, by inverting the exact sign-flip test of their sum over all
    2^W sign patterns.

    A value delta is rejected (too large) when the observed sum of
    (d_w - delta) is among the lowest alpha of its sign-flipped sums. The
    flipped sum is no larger than the observed one exactly when the flipped
    writers' mean difference is at least delta (or none is flipped), so with
    N = 2^W the p-value is (1 + #{non-empty S: mean_S(d) >= delta}) / N, and
    the bound is the k-th largest non-empty subset mean, k = floor(alpha N).
    With k = 0 (fewer than six writers at 2.5 %) nothing is ever rejected:
    the bound does not exist and None is returned.

    Counted exactly, without listing subsets: differences are rationals, so
    scaled to integers the subsets are counted by size and sum."""
    w = len(differences)
    if w == 0:
        raise ValueError("no writers")
    k = math.floor(alpha * 2**w)
    if k == 0:
        return None
    scale = math.lcm(*(Fraction(d).denominator for d in differences))
    values = [int(Fraction(d) * scale) for d in differences]
    # counts[size][sum] = number of subsets of that size with that scaled sum.
    counts: list[dict[int, int]] = [{0: 1}] + [{} for _ in range(w)]
    for v in values:
        for size in range(w - 1, -1, -1):
            for total, n in counts[size].items():
                cell = counts[size + 1]
                cell[total + v] = cell.get(total + v, 0) + n
    means = sorted(((Fraction(total, size), n) for size in range(1, w + 1) for total, n in counts[size].items()),
                   reverse=True)
    seen = 0
    for mean, n in means:
        seen += n
        if seen >= k:
            return mean / scale
    raise AssertionError("k never exceeds the number of non-empty subsets")


def verdict(upper: float | Fraction | None, tied_at_zero: bool) -> str:
    """The parity rule on one comparison: pass only when the bound is at most
    zero. A missing bound is unresolved, never a pass. `tied_at_zero` marks
    a bound of exactly zero that comes only from writers with no difference;
    the protocol states that data with no paired errors never passes, so the
    literal sign-flip result there is reported as unresolved for a ruling
    (docs/plan.md, stage 4)."""
    if upper is None:
        return "unresolved"
    if upper == 0 and tied_at_zero:
        return "unresolved"
    return "pass" if upper <= 0 else "fail"


# EVAL02 sample size.


def _xlogy(x: int, p: float) -> float:
    """x log p, with 0 log 0 = 0."""
    if x == 0:
        return 0.0
    return x * math.log(p) if p > 0 else -math.inf


def tango_power(n: int, p_b: float, p_c: float, alpha: Fraction = ALPHA) -> float:
    """The exact probability that a holdout of n items gives an upper bound
    at most zero when items fail for the candidate only at rate p_b and for
    the reference only at rate p_c. The bound rises with b, so for each c
    the passing b run from zero to a largest value, found by halving."""
    if not (0 <= p_b and 0 < p_c and p_b + p_c <= 1):
        raise ValueError("rates must be probabilities with a reference-only rate above zero")
    rest = 1 - p_b - p_c
    total = 0.0
    for c in range(n + 1):
        if tango_upper(0, c, n, alpha) > 0:
            continue
        lo, hi = 0, n - c
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if tango_upper(mid, c, n, alpha) <= 0:
                lo = mid
            else:
                hi = mid - 1
        for b in range(lo + 1):
            log_p = (math.lgamma(n + 1) - math.lgamma(b + 1) - math.lgamma(c + 1) - math.lgamma(n - b - c + 1)
                     + _xlogy(b, p_b) + _xlogy(c, p_c) + _xlogy(n - b - c, rest))
            total += math.exp(log_p)
    return total


def tango_sample_size(p_b: float, p_c: float, alpha: Fraction = ALPHA, power: float = POWER,
                      largest: int = 20000) -> dict:
    """The smallest holdout size whose exact power reaches `power`, found by
    doubling then halving. Power is not quite monotone in n (the counts are
    whole numbers), so the size found is checked and its exact power
    reported. A candidate no better than the reference (p_b >= p_c) cannot
    pass at any size, as the protocol says, and gets no size."""
    if p_b >= p_c:
        return {"items": None, "power": None,
                "reason": "the candidate is no better than the reference on development data; no size can pass it"}
    n = 8
    while tango_power(n, p_b, p_c, alpha) < power:
        n *= 2
        if n > largest:
            return {"items": None, "power": None, "reason": f"more than {largest} items would be needed"}
    lo, hi = n // 2, n
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if tango_power(mid, p_b, p_c, alpha) >= power:
            hi = mid
        else:
            lo = mid
    return {"items": hi, "power": tango_power(hi, p_b, p_c, alpha), "reason": None}
