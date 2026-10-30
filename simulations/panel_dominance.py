"""
Biased-minority panel analysis for RegDAO (Section V-E, Appendix D, Table 9).

Under the two-thirds approval rule, a panel of size theta needs
A(theta) = ceil(2*theta/3) approvals. A biased minority of size b can
  - block approval by holding  k_B = theta - A + 1 seats, or
  - force approval by holding  k_F = A seats.
Panel members are drawn uniformly without replacement from N qualified
members, so the number of biased panelists is hypergeometric.

Usage:
    python3 panel_dominance.py            # prints Table 9 and the N = 50 illustration
    python3 panel_dominance.py --b 5      # different biased-group size
"""
import argparse
from math import comb


def approvals_required(theta: int) -> int:
    """A(theta) = ceil(2*theta/3), using integers to avoid float rounding."""
    return -(-2 * theta // 3)


def block_seats(theta: int) -> int:
    return theta - approvals_required(theta) + 1


def tail_prob(N: int, b: int, theta: int, k: int) -> float:
    """P(X >= k) for X ~ Hypergeometric(N, b, theta)."""
    if theta > N:
        raise ValueError("panel larger than population")
    total = comb(N, theta)
    return sum(comb(b, x) * comb(N - b, theta - x)
               for x in range(k, min(b, theta) + 1)) / total


def n_min(b: int, theta: int, k: int, eps: float, n_max: int = 100_000):
    """Smallest N with P(X >= k) <= eps; None if the minority can never reach k seats."""
    if k > b:
        return None
    N = max(theta, b)
    while N <= n_max:
        if tail_prob(N, b, theta, k) <= eps:
            return N
        N += 1
    raise RuntimeError("n_max exceeded")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--b", type=int, default=3, help="biased-group size")
    ap.add_argument("--thetas", type=int, nargs="+", default=[3, 5, 6, 7, 9])
    ap.add_argument("--eps", type=float, nargs="+", default=[0.01, 0.05])
    args = ap.parse_args()

    print(f"Table 9: minimum qualified population N_min with P_block <= eps (b = {args.b})\n")
    header = f"{'theta':>5} {'A':>3} {'k_B':>4} {'k_F':>4} " + " ".join(f"{'eps=' + str(e):>10}" for e in args.eps)
    print(header)
    for t in args.thetas:
        A, kb = approvals_required(t), block_seats(t)
        cells = []
        for e in args.eps:
            v = n_min(args.b, t, kb, e)
            cells.append(f"{'none' if v is None else v:>10}")
        print(f"{t:>5} {A:>3} {kb:>4} {A:>4} " + " ".join(cells))
    print("\n'none' = the minority cannot reach k_B seats, so P_block = 0 for every N.")

    print(f"\nIllustration at N = 50, b = {args.b}:")
    for t in args.thetas:
        kb = block_seats(t)
        p = tail_prob(50, args.b, t, kb) if kb <= args.b else 0.0
        print(f"  theta = {t}: P_block = {p:.4%}")

    print("\nCheck of the values in the rejected manuscript (b = 3, all-seat formula):")
    for t, N in [(3, 14), (5, 8)]:
        print(f"  theta = {t}, N = {N}: actual P_block = {tail_prob(N, 3, t, block_seats(t)):.1%}")


if __name__ == "__main__":
    main()
