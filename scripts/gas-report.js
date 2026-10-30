// scripts/gas-report.js
//
// Measures gas for every state-changing step of the RegDAO proposal lifecycle on a local Hardhat
// network, plus how settlement gas scales with the number of reasoned endorsements.
// Writes reports/gas-report.md and reports/gas-report.json.
//
// Usage:
//   npx hardhat run scripts/gas-report.js            (LOCAL_SOLC=1 for offline compilation)

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const { ethers } = hre;
const E = (n) => ethers.parseEther(String(n));
const FULL = 0x3f;
const REASON = "Article 12(3) conflicts with the VASP reporting rule; see FSC guidance 2024-17 for the same issue.";
const SETTLE_SIZES = [3, 10, 25, 50, 100];

async function gasOf(txPromise) {
  const receipt = await (await txPromise).wait();
  return Number(receipt.gasUsed);
}

async function setup(endorserCount) {
  const signers = await ethers.getSigners();
  const [admin, proposer, ed1, ed2, r1, r2, r3] = signers;
  const endorsers = signers.slice(7, 7 + endorserCount);
  if (endorsers.length < endorserCount) throw new Error("not enough accounts; raise networks.hardhat.accounts.count");

  const badge = await (await ethers.getContractFactory("BadgeSBT")).deploy(admin.address);
  const rdao = await (await ethers.getContractFactory("RDAOToken")).deploy(admin.address);
  const board = await (await ethers.getContractFactory("ProposalBoard")).deploy(
    await badge.getAddress(), await rdao.getAddress(), admin.address);
  const pr = await (await ethers.getContractFactory("PeerReview")).deploy(
    await badge.getAddress(), await rdao.getAddress(), admin.address);

  const deployGas = {};
  for (const [name, c] of [["BadgeSBT", badge], ["RDAOToken", rdao], ["ProposalBoard", board], ["PeerReview", pr]]) {
    deployGas[name] = Number((await c.deploymentTransaction().wait()).gasUsed);
  }

  const POINTS_ROLE = await badge.POINTS_ROLE();
  await badge.grantRole(POINTS_ROLE, await board.getAddress());
  await badge.grantRole(POINTS_ROLE, await pr.getAddress());
  await rdao.setMinter(await board.getAddress(), true);
  await rdao.setMinter(await pr.getAddress(), true);
  await board.setPeerReview(await pr.getAddress());
  await pr.setBoard(await board.getAddress());
  await board.setMaxEndorsementsPerPost(Math.max(100, endorserCount));

  await badge.mintAt(proposer.address, 1);
  for (const s of endorsers) await badge.mintAt(s.address, 1);
  for (const s of [ed1, ed2]) await badge.mintAt(s.address, 4);
  for (const s of [r1, r2, r3]) await badge.mintAt(s.address, 3);
  for (const s of [proposer, ed1, ed2, r1, r2, r3, ...endorsers]) {
    await rdao.mint(s.address, E(1000));
    await rdao.connect(s).approve(await board.getAddress(), ethers.MaxUint256);
    await rdao.connect(s).approve(await pr.getAddress(), ethers.MaxUint256);
  }
  return { badge, rdao, board, pr, admin, proposer, ed1, ed2, reviewers: [r1, r2, r3], endorsers, deployGas };
}

/** Full lifecycle with three endorsers; returns gas per step. `approve` picks the verdict. */
async function lifecycle(approve) {
  const ctx = await setup(3);
  const { board, pr, proposer, ed1, ed2, reviewers, endorsers } = ctx;
  const g = {};

  g["ProposalBoard.createPost (incl. S_PRO transfer)"] = await gasOf(
    board.connect(proposer).createPost(0, "Proposal", "Amend Article 12(3).", ""));
  const ePos = [];
  for (let i = 0; i < 3; i++) {
    ePos.push(await gasOf(board.connect(endorsers[i]).endorsePost(1, true, REASON)));
  }
  g["ProposalBoard.endorsePost (incl. S_RE transfer)"] = ePos[0];
  g["ProposalBoard.recordFCC — first pass (pays dP_RE and dP_PRO)"] = await gasOf(board.recordFCC(1, FULL));
  g["ProposalBoard.recordFCC — later pass (dP_RE only)"] = await gasOf(board.recordFCC(2, FULL));
  g["ProposalBoard.recordFCC — pass that triggers referral"] = await gasOf(board.recordFCC(3, FULL));

  g["PeerReview.initiateCase"] = await gasOf(pr.initiateCase(0, 1, proposer.address, ""));
  g["PeerReview.assignEditors"] = await gasOf(pr.assignEditors(1, ed1.address, ed2.address));
  g["PeerReview.acceptEditorship (incl. S_PPR transfer)"] = await gasOf(pr.connect(ed1).acceptEditorship(1));
  await pr.connect(ed2).acceptEditorship(1);
  const inv = [];
  for (const r of reviewers) inv.push(await gasOf(pr.inviteReviewer(1, r.address)));
  g["PeerReview.inviteReviewer"] = inv[0];
  g["PeerReview.acceptInvite (incl. S_PPR transfer)"] = await gasOf(pr.connect(reviewers[0]).acceptInvite(1, 0));
  await pr.connect(reviewers[1]).acceptInvite(1, 1);
  await pr.connect(reviewers[2]).acceptInvite(1, 2);
  g["PeerReview.submitReview"] = await gasOf(pr.connect(reviewers[0]).submitReview(1, 0, "ipfs://r0", approve));
  await pr.connect(reviewers[1]).submitReview(1, 1, "ipfs://r1", approve);
  g["PeerReview.submitReview — final (verdict + panel payout)"] = await gasOf(
    pr.connect(reviewers[2]).submitReview(1, 2, "ipfs://r2", approve));
  g[`ProposalBoard.settle — ${approve ? "approved" : "rejected"}, 3 REs`] = await gasOf(board.settle(1, 1));
  if (approve) {
    g["PeerReview.publishFinalProposal"] = await gasOf(
      pr.connect(ed1).publishFinalProposal(1, "Final", "ipfs://final", "summary"));
  }
  return { gas: g, deployGas: ctx.deployGas };
}

async function settleScaling(k, approve) {
  const { board, pr, proposer, ed1, ed2, reviewers, endorsers } = await setup(k);
  await board.connect(proposer).createPost(0, "Proposal", "Amend Article 12(3).", "");
  for (let i = 0; i < k; i++) {
    await board.connect(endorsers[i]).endorsePost(1, true, REASON);
    await board.recordFCC(i + 1, FULL);
  }
  await pr.initiateCase(0, 1, proposer.address, "");
  await pr.assignEditors(1, ed1.address, ed2.address);
  await pr.connect(ed1).acceptEditorship(1);
  await pr.connect(ed2).acceptEditorship(1);
  for (let i = 0; i < 3; i++) await pr.inviteReviewer(1, reviewers[i].address);
  for (let i = 0; i < 3; i++) await pr.connect(reviewers[i]).acceptInvite(1, i);
  for (let i = 0; i < 3; i++) await pr.connect(reviewers[i]).submitReview(1, i, "ipfs://r", approve);
  return gasOf(board.settle(1, 1));
}

async function main() {
  const approved = await lifecycle(true);
  const rejected = await lifecycle(false);

  const scaling = [];
  for (const k of SETTLE_SIZES) {
    scaling.push({ endorsements: k, approved: await settleScaling(k, true), rejected: await settleScaling(k, false) });
  }

  const steps = { ...approved.gas };
  for (const [k, v] of Object.entries(rejected.gas)) if (k.includes("rejected")) steps[k] = v;

  const solc = hre.config.solidity.compilers[0];
  const lines = [];
  lines.push("# RegDAO gas report", "");
  lines.push(`Measured on the local Hardhat network (EVM ${solc.settings.evmVersion}), solc ${solc.version}, ` +
    `optimizer ${solc.settings.optimizer.runs} runs, viaIR ${solc.settings.viaIR}. ` +
    "Regenerate with `npx hardhat run scripts/gas-report.js`.", "");
  lines.push("## Deployment", "", "| Contract | Gas |", "|---|---:|");
  for (const [k, v] of Object.entries(approved.deployGas)) lines.push(`| ${k} | ${v.toLocaleString("en-US")} |`);
  lines.push("", "## Proposal lifecycle (3 reasoned endorsements, 3 reviewers)", "", "| Step | Gas |", "|---|---:|");
  for (const [k, v] of Object.entries(steps)) lines.push(`| ${k} | ${v.toLocaleString("en-US")} |`);
  lines.push("", "## Settlement gas vs. number of FCC-passed supporting endorsements", "",
    "| Endorsements | Approved | Rejected | Rejected, per participant (proposer + endorsers) |", "|---:|---:|---:|---:|");
  for (const r of scaling) {
    lines.push(`| ${r.endorsements} | ${r.approved.toLocaleString("en-US")} | ${r.rejected.toLocaleString("en-US")} | ` +
      `${Math.round(r.rejected / (r.endorsements + 1)).toLocaleString("en-US")} |`);
  }
  lines.push("");

  const outDir = path.join(__dirname, "..", "reports");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "gas-report.md"), lines.join("\n"));
  fs.writeFileSync(path.join(outDir, "gas-report.json"),
    JSON.stringify({ deployment: approved.deployGas, lifecycle: steps, settleScaling: scaling }, null, 2) + "\n");
  console.log(lines.join("\n"));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
