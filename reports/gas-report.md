# RegDAO gas report

Measured on the local Hardhat network (EVM cancun), solc 0.8.36, optimizer 200 runs, viaIR true. Regenerate with `npx hardhat run scripts/gas-report.js`.

## Deployment

| Contract | Gas |
|---|---:|
| BadgeSBT | 2,341,162 |
| RDAOToken | 973,118 |
| ProposalBoard | 4,178,539 |
| PeerReview | 3,660,272 |

## Proposal lifecycle (3 reasoned endorsements, 3 reviewers)

| Step | Gas |
|---|---:|
| ProposalBoard.createPost (incl. S_PRO transfer) | 267,439 |
| ProposalBoard.endorsePost (incl. S_RE transfer) | 390,227 |
| ProposalBoard.recordFCC — first pass (counted; points deferred) | 114,488 |
| ProposalBoard.recordFCC — later pass before referral | 80,288 |
| ProposalBoard.recordFCC — pass that triggers referral (pays dP_PRO and all dP_RE) | 266,651 |
| PeerReview.initiateCase | 182,896 |
| PeerReview.assignEditors | 81,352 |
| PeerReview.acceptEditorship (incl. S_PPR transfer) | 110,385 |
| PeerReview.inviteReviewer | 102,505 |
| PeerReview.acceptInvite (incl. S_PPR transfer) | 122,475 |
| PeerReview.submitReview | 105,677 |
| PeerReview.submitReview — final (verdict + panel payout) | 318,950 |
| ProposalBoard.settle — approved, 3 REs | 153,431 |
| PeerReview.publishFinalProposal | 123,995 |
| ProposalBoard.settle — rejected, 3 REs | 318,687 |

## Settlement gas vs. number of FCC-passed supporting endorsements

| Endorsements | Approved | Rejected | Rejected, per participant (proposer + endorsers) |
|---:|---:|---:|---:|
| 3 | 153,431 | 318,687 | 79,672 |
| 10 | 321,208 | 783,810 | 71,255 |
| 25 | 680,729 | 1,780,501 | 68,481 |
| 50 | 1,279,934 | 3,441,656 | 67,483 |
| 100 | 2,478,351 | 6,763,973 | 66,970 |
