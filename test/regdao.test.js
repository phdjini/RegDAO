const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const E = (n) => ethers.parseEther(String(n));
const FULL = 0x3f; // C1..C6 all satisfied
const REASON = "Article 12(3) conflicts with the VASP reporting rule; see FSC guidance 2024-17 for the same issue.";
const S_PRO = E(30);
const S_RE = E(20);
const S_PPR = E(10);
const DAY = 24 * 3600;

// PeerReview.CaseStatus
const AGENDA_ADOPTED = 3;
const AGENDA_PENDING = 4;

async function deploy() {
  const signers = await ethers.getSigners();
  const [admin, proposer, e1, e2, e3, e4, e5, ed1, ed2, r1, r2, r3, r4, low] = signers;

  const badge = await (await ethers.getContractFactory("BadgeSBT")).deploy(admin.address);
  const rdao = await (await ethers.getContractFactory("RDAOToken")).deploy(admin.address);
  const board = await (await ethers.getContractFactory("ProposalBoard")).deploy(
    await badge.getAddress(), await rdao.getAddress(), admin.address);
  const pr = await (await ethers.getContractFactory("PeerReview")).deploy(
    await badge.getAddress(), await rdao.getAddress(), admin.address);

  const POINTS_ROLE = await badge.POINTS_ROLE();
  await badge.grantRole(POINTS_ROLE, await board.getAddress());
  await badge.grantRole(POINTS_ROLE, await pr.getAddress());
  await rdao.setMinter(await board.getAddress(), true);
  await rdao.setMinter(await pr.getAddress(), true);
  await board.setPeerReview(await pr.getAddress());
  await pr.setBoard(await board.getAddress());

  // tiers: 1 = Member-Bronze, 2 = Silver, 3 = Gold, 4 = Council
  await badge.mintAt(proposer.address, 1);
  for (const s of [e1, e2, e3, e4, e5]) await badge.mintAt(s.address, 1);
  for (const s of [ed1, ed2]) await badge.mintAt(s.address, 4);
  for (const s of [r1, r2, r3, r4]) await badge.mintAt(s.address, 3);
  await badge.mintAt(low.address, 2);

  for (const s of [proposer, e1, e2, e3, e4, e5, ed1, ed2, r1, r2, r3, r4, low]) {
    await rdao.mint(s.address, E(1000));
    await rdao.connect(s).approve(await board.getAddress(), ethers.MaxUint256);
    await rdao.connect(s).approve(await pr.getAddress(), ethers.MaxUint256);
  }
  return { badge, rdao, board, pr, admin, proposer, e1, e2, e3, e4, e5, ed1, ed2, r1, r2, r3, r4, low };
}

async function post(ctx, author = ctx.proposer) {
  await ctx.board.connect(author).createPost(0, "Proposal", "Amend Article 12(3).", "");
  return Number(await ctx.board.postCount());
}

async function endorse(ctx, postId, who, isSupport, mask = FULL) {
  await ctx.board.connect(who).endorsePost(postId, isSupport, REASON);
  const id = Number(await ctx.board.endorsementCount());
  if (mask !== null) await ctx.board.recordFCC(id, mask);
  return id;
}

/** Runs a referred proposal through peer review; votes = array of booleans for r1..r3. */
async function review(ctx, postId, votes) {
  const { pr, proposer, ed1, ed2 } = ctx;
  await pr.initiateCase(0, postId, proposer.address, "");
  const caseId = Number(await pr.caseCount());
  await pr.assignEditors(caseId, ed1.address, ed2.address);
  await pr.connect(ed1).acceptEditorship(caseId);
  await pr.connect(ed2).acceptEditorship(caseId);
  const reviewers = [ctx.r1, ctx.r2, ctx.r3];
  for (const r of reviewers) await pr.inviteReviewer(caseId, r.address);
  for (let i = 0; i < 3; i++) await pr.connect(reviewers[i]).acceptInvite(caseId, i);
  for (let i = 0; i < 3; i++) await pr.connect(reviewers[i]).submitReview(caseId, i, "ipfs://review", votes[i]);
  return caseId;
}

describe("RegDAO — manuscript-aligned mechanisms", function () {
  let ctx;
  beforeEach(async () => { ctx = await deploy(); });

  describe("Soulbound badge", function () {
    it("is non-transferable and tracks |M|", async () => {
      const { badge, proposer, e1 } = ctx;
      expect(await badge.memberCount()).to.equal(13);
      const tokenId = await badge.tokenIdOf(proposer.address);
      await expect(badge.connect(proposer).transferFrom(proposer.address, e1.address, tokenId))
        .to.be.revertedWith("BadgeSBT: soulbound, non-transferable");
    });
  });

  describe("Reasoned endorsement and FCC (Section IV-C)", function () {
    it("requires a stake and a reason of at least 50 bytes", async () => {
      const { board, rdao, proposer, e1 } = ctx;
      const before = await rdao.balanceOf(proposer.address);
      const postId = await post(ctx);
      expect(before - (await rdao.balanceOf(proposer.address))).to.equal(S_PRO);
      await expect(board.connect(e1).endorsePost(postId, true, "too short"))
        .to.be.revertedWith("ProposalBoard: a substantive reason is required");
    });

    it("pays dP_RE = 2 per passing RE and dP_PRO = 3 only once, independent of direction", async () => {
      const { badge, board, proposer, e1, e2 } = ctx;
      const postId = await post(ctx);
      const p0 = await badge.pointsOf(proposer.address);
      const a0 = await badge.pointsOf(e1.address);
      await endorse(ctx, postId, e1, false); // opposition also counts
      await endorse(ctx, postId, e2, true);
      expect((await badge.pointsOf(proposer.address)) - p0).to.equal(3);
      expect((await badge.pointsOf(e1.address)) - a0).to.equal(2);
      const p = await board.posts(postId);
      expect(p.verifiedCount).to.equal(2);
    });

    it("does not count an RE that fails any checklist item, and allows one appeal", async () => {
      const { board, badge, e1 } = ctx;
      const postId = await post(ctx);
      const a0 = await badge.pointsOf(e1.address);
      const id = await endorse(ctx, postId, e1, true, FULL & ~(1 << 3)); // C4 fails
      expect((await board.endorsements(id)).fcc).to.equal(2); // FAILED
      expect((await board.posts(postId)).verifiedCount).to.equal(0);
      await board.connect(e1).appealFCC(id);
      await board.recordFCC(id, FULL);
      expect((await board.posts(postId)).verifiedCount).to.equal(1);
      expect((await badge.pointsOf(e1.address)) - a0).to.equal(2);
      await expect(board.connect(e1).appealFCC(id)).to.be.revertedWith("ProposalBoard: only failed REs can be appealed");
    });

    it("refers a proposal once N_RE >= theta_PR = max(theta_min, ceil(rho*|M|))", async () => {
      const { board, pr, proposer, e1, e2, e3 } = ctx;
      expect(await board.referralThreshold()).to.equal(3); // ceil(0.05 * 13) = 1 < theta_min = 3
      await board.setReferralParams(3, 3000);              // ceil(0.30 * 13) = 4
      expect(await board.referralThreshold()).to.equal(4);
      await board.setReferralParams(3, 500);

      const postId = await post(ctx);
      await endorse(ctx, postId, e1, true);
      await endorse(ctx, postId, e2, true);
      await expect(pr.initiateCase(0, postId, proposer.address, ""))
        .to.be.revertedWith("PeerReview: proposal has not reached theta_PR");
      await expect(board.connect(e3).endorsePost(postId, true, REASON)).to.not.be.reverted;
      await expect(board.recordFCC(Number(await board.endorsementCount()), FULL))
        .to.emit(board, "ReferredToPeerReview").withArgs(postId, 3, 3);
    });
  });

  describe("Settlement on the verdict (Table 2, Appendix A-2)", function () {
    it("approval returns every deposit and pays RDAO", async () => {
      const { board, rdao, proposer, e1, e2, e3 } = ctx;
      const postId = await post(ctx);
      for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
      const b0 = await rdao.balanceOf(proposer.address);
      const caseId = await review(ctx, postId, [true, true, false]); // 2/3 approve
      await board.settle(postId, caseId);
      expect((await rdao.balanceOf(proposer.address)) - b0).to.equal(S_PRO + E(20));
      expect(await rdao.balanceOf(e1.address)).to.equal(E(1000) + E(5));
    });

    it("rejection slashes the proposer and supporters but exempts opposers and failed REs", async () => {
      const { board, rdao, proposer, e1, e2, e3, e4, e5 } = ctx;
      // first rejection is a grace round (lambda(1) = 0), so reject once to reach lambda(2) = 30%
      for (let round = 1; round <= 2; round++) {
        const postId = await post(ctx);
        for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
        await endorse(ctx, postId, e4, false);       // opposed beforehand
        await endorse(ctx, postId, e5, true, 0x1f);  // fails C6
        const caseId = await review(ctx, postId, [false, false, true]);
        expect((await ctx.pr.cases(caseId)).status).to.equal(AGENDA_PENDING);
        const before = {
          p: await rdao.balanceOf(proposer.address),
          s: await rdao.balanceOf(e1.address),
          o: await rdao.balanceOf(e4.address),
          f: await rdao.balanceOf(e5.address),
        };
        await board.settle(postId, caseId);
        const rate = round === 1 ? 0n : 3000n;
        expect((await rdao.balanceOf(proposer.address)) - before.p).to.equal(S_PRO - (S_PRO * rate) / 10000n);
        expect((await rdao.balanceOf(e1.address)) - before.s).to.equal(S_RE - (S_RE * rate) / 10000n);
        expect((await rdao.balanceOf(e4.address)) - before.o).to.equal(S_RE);
        expect((await rdao.balanceOf(e5.address)) - before.f).to.equal(S_RE);
      }
      expect(await board.rejectionsInWindow(proposer.address)).to.equal(2);
      expect(await board.rejectionsInWindow(e4.address)).to.equal(0);
    });

    it("applies lambda(n) = 0, 30, 60, 100% and resets after the 90-day window", async () => {
      const { board, rdao, proposer, e1, e2, e3 } = ctx;
      const burned = [];
      for (let round = 1; round <= 5; round++) {
        if (round === 5) await time.increase(91 * DAY);
        const postId = await post(ctx);
        for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
        const caseId = await review(ctx, postId, [false, false, false]);
        const b0 = await rdao.balanceOf(proposer.address);
        await board.settle(postId, caseId);
        burned.push(S_PRO - ((await rdao.balanceOf(proposer.address)) - b0));
      }
      expect(burned).to.deep.equal([0n, E(9), E(18), E(30), 0n]);
    });

    it("reproduces Table 8 (g = 5, S = 50, N* = 2) for a two-member coalition", async () => {
      const { board, badge, rdao, proposer, e1 } = ctx;
      await board.setReferralParams(1, 0); // one RE suffices, as in Appendix B
      let cumGain = 0n, cumLoss = 0n, nStar = 0;
      const rows = [];
      for (let n = 1; n <= 3; n++) {
        const pts0 = (await badge.pointsOf(proposer.address)) + (await badge.pointsOf(e1.address));
        const bal0 = (await rdao.balanceOf(proposer.address)) + (await rdao.balanceOf(e1.address));
        const postId = await post(ctx);
        await endorse(ctx, postId, e1, true);
        const caseId = await review(ctx, postId, [false, false, false]);
        await board.settle(postId, caseId);
        const g = (await badge.pointsOf(proposer.address)) + (await badge.pointsOf(e1.address)) - pts0;
        const loss = bal0 - ((await rdao.balanceOf(proposer.address)) + (await rdao.balanceOf(e1.address)));
        cumGain += g;
        cumLoss += loss / E(1);
        rows.push([n, Number(g), Number(loss / E(1))]);
        if (!nStar && cumLoss >= cumGain) nStar = n;
      }
      expect(rows).to.deep.equal([[1, 5, 0], [2, 5, 15], [3, 5, 30]]);
      expect(nStar).to.equal(2);
    });

    it("lets un-referred proposals expire with full refunds", async () => {
      const { board, rdao, proposer, e1 } = ctx;
      const postId = await post(ctx);
      await endorse(ctx, postId, e1, true);
      await expect(board.expire(postId)).to.be.revertedWith("ProposalBoard: not yet expired");
      await time.increase(91 * DAY);
      await board.expire(postId);
      expect(await rdao.balanceOf(proposer.address)).to.equal(E(1000));
      expect(await rdao.balanceOf(e1.address)).to.equal(E(1000));
    });

    it("rejects an invalid burn schedule", async () => {
      await expect(ctx.board.setBurnSchedule([0, 5000, 3000, 10000])).to.be.revertedWith("schedule must be non-decreasing");
      await expect(ctx.board.setBurnSchedule([0, 5000])).to.be.revertedWith("schedule must reach 100%");
    });
  });

  describe("Peer-review panel (Section IV-D, Appendix A-3)", function () {
    it("enforces Council+ editors and Member-Gold+ reviewers", async () => {
      const { pr, proposer, e1, e2, e3, ed1, r1, low } = ctx;
      const postId = await post(ctx);
      for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
      await pr.initiateCase(0, postId, proposer.address, "");
      await expect(pr.assignEditors(1, ed1.address, r1.address)).to.be.revertedWith("PeerReview: co-editor must be Council+");
      await pr.assignEditors(1, ed1.address, ctx.ed2.address);
      await pr.connect(ed1).acceptEditorship(1);
      await pr.connect(ctx.ed2).acceptEditorship(1);
      await expect(pr.inviteReviewer(1, low.address)).to.be.revertedWith("PeerReview: reviewer must be Member-Gold+");
    });

    it("pays the panel deposit, points and RDAO regardless of verdict", async () => {
      const { pr, rdao, badge, e1, e2, e3, ed1, r1, r2 } = ctx;
      const postId = await post(ctx);
      for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
      const pts = { r1: await badge.pointsOf(r1.address), r2: await badge.pointsOf(r2.address) };
      const caseId = await review(ctx, postId, [true, false, false]); // rejected
      expect((await pr.cases(caseId)).status).to.equal(AGENDA_PENDING);
      // approve-voter and reject-voter are treated identically
      expect(await rdao.balanceOf(r1.address)).to.equal(E(1000) + E(20));
      expect(await rdao.balanceOf(r2.address)).to.equal(E(1000) + E(20));
      expect((await badge.pointsOf(r1.address)) - pts.r1).to.equal(20);
      expect((await badge.pointsOf(r2.address)) - pts.r2).to.equal(20);
      expect(await rdao.balanceOf(ed1.address)).to.equal(E(1000) + E(30));
    });

    it("burns part of a no-show reviewer's deposit and reopens the seat", async () => {
      const { pr, rdao, proposer, e1, e2, e3, ed1, ed2, r1, r2, r3, r4 } = ctx;
      const postId = await post(ctx);
      for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
      await pr.initiateCase(0, postId, proposer.address, "");
      await pr.assignEditors(1, ed1.address, ed2.address);
      await pr.connect(ed1).acceptEditorship(1);
      await pr.connect(ed2).acceptEditorship(1);
      for (const r of [r1, r2, r3, r4]) await pr.inviteReviewer(1, r.address);
      for (let i = 0; i < 3; i++) await pr.connect([r1, r2, r3][i]).acceptInvite(1, i);
      await expect(pr.connect(r4).acceptInvite(1, 3)).to.be.revertedWith("PeerReview: not recruiting reviewers");
      await pr.connect(r1).submitReview(1, 0, "ipfs://a", true);
      await pr.connect(r2).submitReview(1, 1, "ipfs://b", true);
      await expect(pr.markNoShow(1, 2)).to.be.revertedWith("PeerReview: deadline not passed");
      await time.increase(15 * DAY);
      await pr.markNoShow(1, 2);
      expect(await rdao.balanceOf(r3.address)).to.equal(E(1000) - S_PPR / 2n);
      await pr.connect(r4).acceptInvite(1, 3);
      await pr.connect(r4).submitReview(1, 3, "ipfs://d", true);
      expect((await pr.cases(1)).status).to.equal(AGENDA_ADOPTED);
    });

    it("refunds panel deposits without reward when a case is cancelled", async () => {
      const { pr, rdao, proposer, e1, e2, e3, ed1, ed2 } = ctx;
      const postId = await post(ctx);
      for (const e of [e1, e2, e3]) await endorse(ctx, postId, e, true);
      await pr.initiateCase(0, postId, proposer.address, "");
      await pr.assignEditors(1, ed1.address, ed2.address);
      await pr.connect(ed1).acceptEditorship(1);
      await pr.cancelCase(1, "test");
      expect(await rdao.balanceOf(ed1.address)).to.equal(E(1000));
    });
  });
});
