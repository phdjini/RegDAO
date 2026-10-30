require("dotenv").config();
const { peerReview, profile, badge, board } = require("./chain");
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
    if (status !== 1) continue; // 리뷰어 모집 중(RECRUITING_REVIEWERS)인 케이스만 재초대 가능

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
      const pool = [];
      for (const m of profiledMembers) {
        if (excludeAddrs.includes(m.address.toLowerCase())) continue;
        if (Number(await badge.tierOf(m.address)) >= 3 /* Member-Gold */) pool.push(m);
      }
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

/** 리뷰 마감이 지난 IN_REVIEW 케이스에서 미제출 리뷰어를 no-show로 처리한다 (예치금 일부 소각, 좌석 재개방). */
async function markNoShows() {
  const caseCount = Number(await peerReview.caseCount());
  const nowSec = Math.floor(Date.now() / 1000);
  for (let caseId = 1; caseId <= caseCount; caseId++) {
    const c = await peerReview.cases(caseId);
    if (Number(c.status) !== 2 /* IN_REVIEW */) continue;
    const st = await peerReview.editorState(caseId);
    if (nowSec <= Number(st.reviewDeadline)) continue;
    const n = Number(await peerReview.reviewersCount(caseId));
    for (let i = 0; i < n; i++) {
      const inv = await peerReview.reviewersOf(caseId, i);
      if (Number(inv.status) === 1 /* ACCEPTED */ && !inv.reviewSubmitted) {
        console.log(`[case ${caseId}] 리뷰어 #${i} (${inv.reviewer}) 마감 초과 -> no-show 처리`);
        await (await peerReview.markNoShow(caseId, i)).wait();
      }
    }
  }
}

/** 판정이 난 정책제안 케이스의 예치금을 정산한다 (누구나 호출 가능한 settle을 에이전트가 대신 호출). */
async function settleDecided() {
  const caseCount = Number(await peerReview.caseCount());
  for (let caseId = 1; caseId <= caseCount; caseId++) {
    const c = await peerReview.cases(caseId);
    const status = Number(c.status);
    if (Number(c.caseType) !== 0 || ![3, 4, 5].includes(status)) continue;
    const post = await board.posts(c.sourcePostId);
    if (Number(post.outcome) !== 0 /* OPEN */) continue;
    console.log(`[case ${caseId}] 안건 #${c.sourcePostId} 예치금 정산`);
    await (await board.settle(c.sourcePostId, caseId)).wait();
  }
}

async function main() {
  console.log("=== 초대 시간초과 점검 실행 ===", new Date().toISOString());
  await escalateTimedOutInvites();
  await markNoShows();
  await settleDecided();
  console.log("=== 점검 완료 ===");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { main };
