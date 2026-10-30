# RegDAO — DAO-Based Multi-Stakeholder Governance for Financial Regulation

Smart contracts, off-chain agent service, simulations and measurements accompanying the manuscript
*"A DAO-Based Multi-Stakeholder Governance Model for Financial Regulation: Design and Implementation of
RegDAO Combining Token-Economy Incentives and Peer Review."*

RegDAO is a public–private consultative platform in which financial authorities, industry, academia,
law and accounting firms, and legislative and executive officials propose and verify regulatory-policy
proposals on a public blockchain. Voting authority comes from non-transferable reputation badges; economic
incentives come from a separate transferable utility token, so that authority cannot be bought.

## Where each mechanism in the manuscript is implemented

| Manuscript | Mechanism | Implementation |
|---|---|---|
| IV-B, Table 1 | Six-tier soulbound reputation badge (0/100/300/600/1200/2500 points) | `BadgeSBT.sol` |
| IV-C, Eq. (1)–(3), Table 6 | Reasoned endorsement (RE), one per member per proposal; formality compliance check C1–C6, pass iff all six | `ProposalBoard.endorsePost`, `ProposalBoard.recordFCC`; checklist in `agent-service/src/fcc.js` |
| IV-C, Eq. (4) | Referral threshold θ_PR = max(θ_min, ⌈ρ·\|M\|⌉) | `ProposalBoard.referralThreshold` |
| IV-D1, Table 2 | Pre-verification points: ΔP_RE = 2 per passing RE, ΔP_PRO = 3 once per proposal | `ProposalBoard.recordFCC` |
| IV-D, Eq. (5) | Two-thirds approval rule | `PeerReview.submitReview` |
| IV-D2, Table 3 | Lead and associate editors Council+, reviewers Member-Gold+, claimant excluded | `PeerReview.assignEditors`, `PeerReview.inviteReviewer` |
| IV-E1, Table 5 | Mandatory pre-staking: S_PRO, S_RE, S_PPR | `ProposalBoard.createPost`, `endorsePost`; `PeerReview.acceptEditorship`, `acceptInvite` |
| V-B, App. A, Eq. (6)–(12) | Progressive slashing λ(n) over a trailing 90-day window; supporters slashed, opposers exempt | `ProposalBoard.settle`, `burnRateBps`, `setBurnSchedule` |
| App. A-3 | Panel immunity: deposit, points and RDAO regardless of verdict; partial burn only for a no-show | `PeerReview._payPanel`, `PeerReview.markNoShow` |
| IV-D | LLM-based editor and reviewer matching | `agent-service/src/claude.js`, `scanNewCases.js` |
| App. B, Table 8 | Deterrence-threshold trajectory | `simulations/deterrence_threshold.py`; verified on-chain in `test/regdao.test.js` |
| V-E, App. D, Table 9 | Biased-minority panel analysis (exact hypergeometric tail) | `simulations/panel_dominance.py` |

### Default parameters

| Symbol | Value | Setter |
|---|---|---|
| τ_FCC | 6 (all items) | `ProposalBoard.setTauFCC` |
| ΔP_PRO, ΔP_RE | 3, 2 points | `setPreVerificationPoints` |
| θ_min, ρ | 3, 5 % of members | `setReferralParams` |
| S_PRO, S_RE, S_PPR | 30, 20, 10 RDAO | `setStakes`, `PeerReview.setPanelStake` |
| λ(1), λ(2), λ(3), λ(n≥4) | 0 %, 30 %, 60 %, 100 % | `setBurnSchedule` (must be non-decreasing and end at 100 %) |
| Rejection window | 90 days | `setRejectionWindow` |
| Review quorum, review period | 3 reviewers, 14 days | `PeerReview.setReviewerQuorum`, `setReviewPeriod` |
| No-show burn | 50 % of S_PPR | `PeerReview.setNoShowBurnBps` |
| Approval rewards | proposer 20, endorser 5, lead editor 30, associate editor 15, reviewer 20 RDAO | `setRewards`, `PeerReview.set*RdaoReward` |

## Lifecycle

1. A member submits a proposal and stakes S_PRO (`createPost`).
2. Bronze+ members submit reasoned support or opposition and stake S_RE (`endorsePost`).
3. The agent service evaluates C1–C6 and records the 6-bit result on-chain (`recordFCC`). Passing REs earn points; the
   first passing RE also pays the proposer. A failed RE can be appealed once.
4. When the number of passing REs reaches θ_PR the proposal is marked *referred*, and the agent opens a peer-review case.
5. Two Council+ editors accept and stake; Gold+ reviewers are invited, accept and stake.
6. Reviewers submit verdicts. The panel is paid as soon as all reviews are in, whatever the verdict.
7. Anyone calls `settle`: on approval every deposit is returned with RDAO; on rejection the proposer and supporting
   endorsers lose λ(n) of their deposit, while opposing endorsers and REs that failed FCC are refunded.
8. A proposal that never reaches θ_PR can be closed with full refunds after 90 days (`expire`).

## Build and test

```bash
npm install
npx hardhat test                 # 15 contract tests
cd agent-service && npm install && npm test   # FCC checklist unit tests
```

If the Solidity compiler cannot be downloaded (restricted networks), prefix commands with `LOCAL_SOLC=1` to compile with
the bundled `solc` package.

## Reproducing the numbers in the manuscript

```bash
npm run simulate        # Table 8 and Table 9 (Python 3, standard library only)
npm run gas             # writes reports/gas-report.md and reports/gas-report.json
```

`reports/gas-report.md` contains deployment gas, gas per lifecycle step, and settlement gas as the number of
endorsements grows (about 67k gas per slashed participant; 100 supporting endorsements settle in about 6.8M gas, within
a single block). The number of REs per proposal is capped at 100 (`setMaxEndorsementsPerPost`) to bound settlement gas.

## Deployment

```bash
printf "PRIVATE_KEY=0x...\nSEPOLIA_RPC_URL=https://...\n" > .env
AGENT_ADDRESS=0x... npx hardhat run scripts/deploy.js --network sepolia
```

The script deploys all contracts, wires roles (points, minting, board ↔ peer review, agent roles) and writes the
addresses to `deployments/sepolia.json`.

## Agent service

`agent-service/` is the off-chain component. It runs the FCC checklist (`processFCC.js`), opens cases for referred
proposals and matches editors and reviewers with the Claude API (`scanNewCases.js`), handles invitation timeouts,
no-shows and settlement (`scheduler.js`), and serves e-mail reply links (`server.js`). Accepting an editor or reviewer
role requires an on-chain stake, so acceptance is done from the dashboard with the member's own wallet; declines can be
relayed by the agent. See `agent-service/README.md` for configuration.

## Repository layout

```
contracts/       BadgeSBT, ProposalBoard, PeerReview, RDAOToken, Charter, DAOGovernance, JoinRegistry,
                 MemberProfile, MembershipFeeVault, CharterStakeVault, BadgeRenderer
test/            Hardhat tests for the manuscript mechanisms
scripts/         deploy.js, gas-report.js, governance demo scripts
simulations/     Python reproductions of Tables 8 and 9
reports/         Generated gas report
agent-service/   FCC checker, AI matching, scheduling, e-mail handling
dashboard/       Single-page member dashboard
```

## Known limitations

- Real names are not detected by the C6 PII check; only structured identifiers (e-mail, phone, resident registration
  and card-like numbers) are.
- C2 and C3 are pattern-based and can be satisfied by reasoning written to match the patterns, including text written
  by a language model. They check form, not substance, as the manuscript states.
- Low-intensity farming confined to the pre-verification stage is not reached by slashing (manuscript Section V-D).
- Editors who accept and then abandon a case are handled only by `cancelCase`, which refunds deposits without penalty.
- `Charter` and `DAOGovernance` (member governance, charter amendments, badge slashing by vote) are unchanged from the
  previous version and are outside the manuscript's analysis.

## Disclaimer

RDAO is an internal utility token for association activities. It is not a stablecoin and carries no guarantee of
exchange for KRW or any other fiat currency.
