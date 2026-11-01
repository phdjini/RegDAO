"""
Cost and time of farming reputation in RegDAO (Results, Table 4; S1 Text, Appendix A).

Points are paid only when a proposal is referred to peer review, so a colluding group must
reach the referral threshold and be rejected by the panel in order to farm. Every rejection
counts towards each member's forfeiture schedule lambda(n), where n is the number of that
member's rejections within the trailing window (90 days by default).

All quantities below follow from the deployed parameters; no valuation of points is assumed.

  * Forfeiture per farmed point at the n-th rejection in a window:
        c(n) = lambda(n) * d,  with d = S_PRO / dP_PRO = S_RE / dP_RE (deposit per point)
  * A member who accepts at most m rejections per window, taking them in one burst and then
    waiting for the window to clear (the cheapest schedule), earns p_bar * m points per window
    and forfeits D_bar * sum_{n<=m} lambda(n) RDAO per window, where p_bar and D_bar are the
    points and deposit per member per round.

Usage:
    python3 farming_cost.py
    python3 farming_cost.py --target 500 --supporters 3 --paces 1 2 4 8 20
"""
import argparse


def lam(n, schedule):
    return schedule[min(n, len(schedule)) - 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--s-pro", type=float, default=30.0)
    ap.add_argument("--s-re", type=float, default=20.0)
    ap.add_argument("--p-pro", type=float, default=3.0)
    ap.add_argument("--p-re", type=float, default=2.0)
    ap.add_argument("--supporters", type=int, default=3, help="theta_min: supporters needed for referral")
    ap.add_argument("--schedule", type=float, nargs="+", default=[0.0, 0.3, 0.6, 1.0])
    ap.add_argument("--window-days", type=float, default=90.0)
    ap.add_argument("--target", type=float, default=500.0, help="points to gain (Bronze 100 -> Gold 600)")
    ap.add_argument("--paces", type=int, nargs="+", default=[1, 2, 4, 8, 20])
    a = ap.parse_args()

    if a.s_pro / a.p_pro != a.s_re / a.p_re:
        print("Note: proposal and endorsement deposits per point differ; c(n) is reported for each.\n")
    d = a.s_re / a.p_re
    print(f"Deposit per point d = {d:g} RDAO\n")
    print("Forfeiture per farmed point by rejection within the window")
    for n in range(1, len(a.schedule) + 1):
        tag = "" if n < len(a.schedule) else " and later"
        print(f"  {n}{tag:>10}: lambda = {lam(n, a.schedule):>4.0%}, cost = {lam(n, a.schedule) * d:g} RDAO per point")

    k = a.supporters + 1
    p_bar = (a.p_pro + a.supporters * a.p_re) / k
    D_bar = (a.s_pro + a.supporters * a.s_re) / k
    print(f"\nMinimal referred coalition: {k} members; per member per round {p_bar:g} points, {D_bar:g} RDAO at stake")
    print(f"\nTable 4: gaining {a.target:g} points per member")
    print(f"{'rejections/window':>18} {'years':>7} {'RDAO burned':>12}")
    for m in a.paces:
        windows = a.target / (p_bar * m)
        years = windows * a.window_days / 365
        burned = windows * D_bar * sum(lam(n, a.schedule) for n in range(1, m + 1))
        print(f"{m:>18} {years:>7.1f} {burned:>12.0f}")
    print(f"{'limit':>18} {'-':>7} {a.target * d:>12.0f}")


if __name__ == "__main__":
    main()
