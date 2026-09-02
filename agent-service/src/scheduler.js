require("dotenv").config();
const { peerReview, profile, badge } = require("./chain");
const { rankCandidates } = require("./claude");
const { sendReviewerInviteEmail } = require("./email");

const TIMEOUT_MS = Number(process.env.INVITE_TIMEOUT_HOURS || 48) * 3600 * 1000;

async function loadAllProfiledMembers() {
  const count = Number(await profile.profiledMemberCount());
  const out = [];
  for (let i = 0; i < count; i++) {
    const addr = await profile.profiledMembers(i);
    const p = await profile.getProfile(addr);
    if (p.exists) out.push({ address: addr, bio: p.bio, interests: p.interests, email: p.email });
  }
  return out;
}

/** 케이스 상태(0 EDITOR_PENDING,1 RECRUITING_REVIEWERS,2 IN_REVIEW)가 진행 중인 것만 대상으로 */
async function escalateTimedOutInvites() {
  const caseCount = Number(await peerReview.caseCount());
  const profiledMembers = await loadAllProfiledMembers();
  const now = Date.now();

  for (let caseId = 1; caseId <= caseCount; caseId++) {
    const c = await peerReview.cases(caseId);
    const status = Number(c.status);
    if (status !== 1 && status !== 2) continue; // 리뷰어 모집중/리뷰중이 아니면 스킵

    const reviewerCount = Number(await peerReview.reviewersCount(caseId));
    const alreadyInvited = [];
    for (let i = 0; i < reviewerCount; i++) {
      const inv = await peerReview.reviewersOf(caseId, i);
      alreadyInvited.push(inv.reviewer.toLowerCase());
      if (Number(inv.status) !== 0) continue; // INVITED 상태만 검사

      const invitedAtMs = Number(inv.invitedAt) * 1000;
      if (now - invitedAtMs < TIMEOUT_MS) continue;

      console.log(`[case ${caseId}] 리뷰어 초대 #${i} (${inv.reviewer}) 시간초과 -> 재배정`);
      const tx = await peerReview.markInviteTimedOut(caseId, i);
      await tx.wait();

      // 아직 초대되지 않은 다음 후보를 Claude로 다시 랭킹해서 1명 추가 초대
      const excludeAddrs = [c.claimant.toLowerCase(), c.chiefEditor.toLowerCase(), c.coEditor.toLowerCase(), ...alreadyInvited];
      const pool = profiledMembers.filter((m) => !excludeAddrs.includes(m.address.toLowerCase()));
      if (pool.length === 0) {
        console.warn(`[case ${caseId}] 재배정할 후보가 더 이상 없습니다.`);
        continue;
      }
      const ranked = await rankCandidates({ title: `case-${caseId}`, content: "" }, pool);
      const nextAddr = ranked[0];
      const nextCandidate = pool.find((m) => m.address.toLowerCase() === nextAddr.toLowerCase());

      const inviteTx = await peerReview.inviteReviewer(caseId, nextAddr);
      await inviteTx.wait();
      const newIdx = Number(await peerReview.reviewersCount(caseId)) - 1;
      console.log(`[case ${caseId}] 새 리뷰어 초대: ${nextAddr} (index ${newIdx})`);

      if (nextCandidate?.email) {
        await sendReviewerInviteEmail({ to: nextCandidate.email, caseId, inviteIndex: newIdx, caseTitle: `안건 #${caseId}`, role: "reviewer" });
      }
    }
  }
}

async function main() {
  console.log("=== 초대 시간초과 점검 실행 ===", new Date().toISOString());
  await escalateTimedOutInvites();
  console.log("=== 점검 완료 ===");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { main };
