"""
Collusion-deterrence threshold for RegDAO (Section V-B, Appendix A-B, Table 8).

A colluding group gains g reputation-equivalent units per round and, when the
proposal is rejected at peer review, loses lambda(n) * S of its stake at the
n-th cumulative rejection. The deterrence threshold is
    N* = min { N : sum_{n=1..N} lambda(n) * S >= N * g }.

Note: the deployed ProposalStakeVault uses a single flat burnBps (default 0),
so these parameters describe the proposed schedule, not the current contracts.

Usage:
    python3 deterrence_threshold.py
    python3 deterrence_threshold.py --g 5 --S 50 --schedule 0 0.3 0.6 1.0
"""
import argparse


def burn_rate(n: int, schedule):
    """lambda(n): schedule[n-1], with the last value held for all later rounds."""
    return schedule[min(n, len(schedule)) - 1]


def trajectory(g: float, S: float, schedule, rounds: int):
    rows, cum_gain, cum_loss, n_star = [], 0.0, 0.0, None
    for n in range(1, rounds + 1):
        lam = burn_rate(n, schedule)
        cum_gain += g
        cum_loss += lam * S
        if n_star is None and cum_loss >= cum_gain:
            n_star = n
        rows.append((n, lam, lam * S, cum_gain, cum_loss))
    return rows, n_star


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--g", type=float, default=5.0, help="per-round gain (dP_PRO + dP_RE)")
    ap.add_argument("--S", type=float, default=50.0, help="total stake per round (RDAO)")
    ap.add_argument("--schedule", type=float, nargs="+", default=[0.0, 0.3, 0.6, 1.0],
                    help="lambda(1), lambda(2), ...; last value repeats")
    ap.add_argument("--rounds", type=int, default=5)
    args = ap.parse_args()

    if any(b < a for a, b in zip(args.schedule, args.schedule[1:])) or args.schedule[-1] < 1.0:
        print("Warning: schedule is not non-decreasing to 1; a finite N* is not guaranteed.\n")

    rows, n_star = trajectory(args.g, args.S, args.schedule, args.rounds)
    print(f"Table 8: g = {args.g}, S = {args.S}\n")
    print(f"{'n':>3} {'lambda':>7} {'round loss':>11} {'cum gain':>9} {'cum loss':>9}")
    for n, lam, loss, cg, cl in rows:
        print(f"{n:>3} {lam:>7.0%} {loss:>11.1f} {cg:>9.1f} {cl:>9.1f}")
    print(f"\nDeterrence threshold N* = {n_star}")


if __name__ == "__main__":
    main()
