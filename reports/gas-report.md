# RegDAO gas report

Measured on the local Hardhat network (EVM cancun), solc 0.8.36, optimizer 200 runs, viaIR true. Regenerate with `npx hardhat run scripts/gas-report.js`.

## Deployment

| Contract | Gas |
|---|---:|
| BadgeSBT | 2,608,895 |
| RDAOToken | 973,118 |
| ProposalBoard | 4,328,628 |
| PeerReview | 3,778,131 |

## Proposal lifecycle (3 reasoned endorsements, 3 reviewers)

| Step | Gas |
|---|---:|
| ProposalBoard.createPost (incl. S_PRO transfer) | 267,701 |
| ProposalBoard.endorsePost (incl. S_RE transfer) | 390,468 |
| ProposalBoard.recordFCC — first pass (pays dP_RE and dP_PRO) | 194,161 |
| ProposalBoard.recordFCC — later pass (dP_RE only) | 134,771 |
| ProposalBoard.recordFCC — pass that triggers referral | 139,494 |
| PeerReview.initiateCase | 183,028 |
| PeerReview.assignEditors | 81,836 |
| PeerReview.acceptEditorship (incl. S_PPR transfer) | 110,407 |
| PeerReview.inviteReviewer | 102,747 |
| PeerReview.acceptInvite (incl. S_PPR transfer) | 122,475 |
| PeerReview.submitReview | 105,677 |
| PeerReview.submitReview — final (verdict + panel payout) | 320,400 |
| ProposalBoard.settle — approved, 3 REs | 153,239 |
| PeerReview.publishFinalProposal | 159,893 |
| ProposalBoard.settle — rejected, 3 REs | 319,668 |

## Settlement gas vs. number of FCC-passed supporting endorsements

| Endorsements | Approved | Rejected | Rejected, per participant (proposer + endorsers) |
|---:|---:|---:|---:|
| 3 | 153,239 | 319,668 | 79,917 |
| 10 | 320,491 | 787,003 | 71,546 |
| 25 | 678,887 | 1,788,434 | 68,786 |
| 50 | 1,276,217 | 3,457,489 | 67,794 |
| 100 | 2,470,884 | 6,795,606 | 67,283 |
