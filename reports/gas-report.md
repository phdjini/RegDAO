# RegDAO gas report

Measured on the local Hardhat network (EVM cancun), solc 0.8.36, optimizer 200 runs, viaIR true. Regenerate with `npx hardhat run scripts/gas-report.js`.

## Deployment

| Contract | Gas |
|---|---:|
| BadgeSBT | 2,608,895 |
| RDAOToken | 973,118 |
| ProposalBoard | 3,839,444 |
| PeerReview | 3,754,747 |

## Proposal lifecycle (3 reasoned endorsements, 3 reviewers)

| Step | Gas |
|---|---:|
| ProposalBoard.createPost (incl. S_PRO transfer) | 267,637 |
| ProposalBoard.endorsePost (incl. S_RE transfer) | 390,403 |
| ProposalBoard.recordFCC — first pass (pays dP_RE and dP_PRO) | 171,791 |
| ProposalBoard.recordFCC — later pass (dP_RE only) | 112,401 |
| ProposalBoard.recordFCC — pass that triggers referral | 117,124 |
| PeerReview.initiateCase | 182,940 |
| PeerReview.assignEditors | 81,836 |
| PeerReview.acceptEditorship (incl. S_PPR transfer) | 110,407 |
| PeerReview.inviteReviewer | 102,747 |
| PeerReview.acceptInvite (incl. S_PPR transfer) | 122,475 |
| PeerReview.submitReview | 105,677 |
| PeerReview.submitReview — final (verdict + panel payout) | 298,180 |
| ProposalBoard.settle — approved, 3 REs | 148,456 |
| PeerReview.publishFinalProposal | 159,893 |
| ProposalBoard.settle — rejected, 3 REs | 314,462 |

## Settlement gas vs. number of FCC-passed supporting endorsements

| Endorsements | Approved | Rejected | Rejected, per participant (proposer + endorsers) |
|---:|---:|---:|---:|
| 3 | 148,456 | 314,462 | 78,616 |
| 10 | 315,196 | 780,298 | 70,936 |
| 25 | 672,498 | 1,778,520 | 68,405 |
| 50 | 1,268,003 | 3,442,225 | 67,495 |
| 100 | 2,459,020 | 6,769,642 | 67,026 |
