require("dotenv").config();
const { board, profile, peerReview, badge } = require("./chain");
const { rankCandidates } = require("./claude");
const { sendReviewerInviteEmail } = require("./email");
const { sendSms } = require("./sms");

const SUPPORT_THRESHOLD = Number(process.env.PEER_REVIEW_SUPPORT_THRESHOLD || 20);

/** 프로필이 등록된 전체 회원 목록을 온체인에서 불러온다. */
async function loadAllProfiledMembers() {
  const count = Number(await profile.profiledMemberCount());
  const out = [];
  for (let i = 0; i < count; i++) {
    const addr = await profile.profiledMembers(i);
    const p = await profile.getProfile(addr);
    if (p.exists) out.push({ address: addr, bio: p.bio, interests: p.interests, email: p.email, phone: p.phone });
  }
  return out;
}

/** 이미 피어리뷰가 개시된 정책제안 postId 집합 (중복 개시 방지, 상태 무관하게 전체 스캔). */
async function loadExistingSourcePostIds() {
  const count = Number(await peerReview.caseCount());
  const set = new Set();
  for (let id = 1; id <= count; id++) {
    const c = await peerReview.cases(id);
    if (Number(c.caseType) === 0) set.add(Number(c.sourcePostId));
  }
  return set;
}

/** 아직 에디터가 배정되지 않은(EDITOR_PENDING) 모든 케이스를 반환한다.
 *  신규 개시 케이스뿐 아니라, 지난 실행에서 에디터 후보 부족으로 보류된 케이스도
 *  여기서 다시 잡혀 자동 재시도된다. */
async function loadPendingEditorCases() {
  const count = Number(await peerReview.caseCount());
  const pending = [];
  for (let id = 1; id <= count; id++) {
    const c = await peerReview.cases(id);
    if (Number(c.status) === 0 /* EDITOR_PENDING */) pending.push(c);
  }
  return pending;
}

async function caseInfoFor(c) {
  if (Number(c.caseType) === 0) {
    const post = await board.posts(Number(c.sourcePostId));
    return { title: post.title, content: post.content };
  }
  return { title: `성과 주장 #${c.id}`, content: c.description };
}

async function inviteTopReviewers(caseId, caseInfo, candidates, excludeAddrs) {
  const pool = candidates.filter((c) => !excludeAddrs.includes(c.address.toLowerCase()));
  if (pool.length === 0) {
    console.warn(`[case ${caseId}] 초대 가능한 리뷰어 후보가 없습니다.`);
    return;
  }
  const rankedAddrs = await rankCandidates(caseInfo, pool);
  const quorum = Number(await peerReview.reviewerQuorum());
  const inviteCount = Math.min(rankedAddrs.length, quorum + 2); // 거절 대비 여유 인원 함께 초대

  for (let i = 0; i < inviteCount; i++) {
    const addr = rankedAddrs[i];
    const candidate = pool.find((c) => c.address.toLowerCase() === addr.toLowerCase());
    const tx = await peerReview.inviteReviewer(caseId, addr);
    await tx.wait();
    const idx = Number(await peerReview.reviewersCount(caseId)) - 1;
    console.log(`[case ${caseId}] 리뷰어 초대: ${addr} (index ${idx})`);

    if (candidate && candidate.email) {
      await sendReviewerInviteEmail({
        to: candidate.email,
        caseId,
        inviteIndex: idx,
        caseTitle: caseInfo.title,
        role: "reviewer",
      });
    } else {
      console.warn(`[case ${caseId}] ${addr}의 이메일이 프로필에 없어 메일을 보내지 못했습니다.`);
    }
    if (candidate && candidate.phone) {
      await sendSms(candidate.phone, `[RegDAO] "${caseInfo.title}" 안건 리뷰어로 위촉되었습니다. 이메일을 확인해 수락/거절해주세요.`);
    }
  }
}

/** EDITOR_PENDING 케이스 하나에 대해 에디터를 배정하고 리뷰어를 초대한다.
 *  Council+ 후보가 2명 미만이면 아무 것도 하지 않고 다음 스캔에서 재시도하도록 남겨둔다. */
async function assignEditorsAndRecruit(c) {
  const caseId = Number(c.id);
  const claimant = c.claimant;
  const caseInfo = await caseInfoFor(c);

  console.log(`\n=== case ${caseId} ("${caseInfo.title}") 에디터 배정 시도 ===`);

  const profiledMembers = await loadAllProfiledMembers();
  const editorCandidates = [];
  for (const m of profiledMembers) {
    if (m.address.toLowerCase() === claimant.toLowerCase()) continue;
    const tier = Number(await badge.tierOf(m.address));
    if (tier >= 4) editorCandidates.push(m);
  }

  if (editorCandidates.length < 2) {
    console.warn(`[case ${caseId}] Council 이상 프로필 등록 회원이 2명 미만이라 이번 스캔에서는 보류합니다 (다음 스캔에서 재시도).`);
    return;
  }

  const rankedEditors = await rankCandidates(caseInfo, editorCandidates);
  const chief = rankedEditors[0];
  const coEditor = rankedEditors.find((a) => a.toLowerCase() !== chief.toLowerCase());

  const assignTx = await peerReview.assignEditors(caseId, chief, coEditor);
  await assignTx.wait();
  console.log(`[case ${caseId}] 에디터 배정 완료: 주에디터 ${chief}, 보조에디터 ${coEditor}`);

  const chiefProfile = editorCandidates.find((c2) => c2.address.toLowerCase() === chief.toLowerCase());
  const coProfile = editorCandidates.find((c2) => c2.address.toLowerCase() === coEditor.toLowerCase());
  if (chiefProfile?.email) {
    await sendReviewerInviteEmail({ to: chiefProfile.email, caseId, inviteIndex: -1, caseTitle: caseInfo.title, role: "editor" });
  }
  if (chiefProfile?.phone) {
    await sendSms(chiefProfile.phone, `[RegDAO] "${caseInfo.title}" 안건의 주에디터로 배정되었습니다.`);
  }
  if (coProfile?.email) {
    await sendReviewerInviteEmail({ to: coProfile.email, caseId, inviteIndex: -1, caseTitle: caseInfo.title, role: "editor" });
  }
  if (coProfile?.phone) {
    await sendSms(coProfile.phone, `[RegDAO] "${caseInfo.title}" 안건의 보조에디터로 배정되었습니다.`);
  }

  await inviteTopReviewers(
    caseId,
    caseInfo,
    profiledMembers,
    [claimant.toLowerCase(), chief.toLowerCase(), coEditor.toLowerCase()]
  );
}

async function main() {
  console.log("=== RegDAO 피어리뷰 스캐너 실행 ===", new Date().toISOString());

  const profiledMembers = await loadAllProfiledMembers();
  if (profiledMembers.length === 0) {
    console.log("프로필이 등록된 회원이 없습니다. 회원들이 먼저 MemberProfile.setProfile()을 호출해야 매칭이 가능합니다.");
    return;
  }

  // 1) 지지수 임계값을 넘긴 신규 정책제안 안건을 케이스로 개시
  const existingPostIds = await loadExistingSourcePostIds();
  const postCount = Number(await board.postCount());
  for (let postId = 1; postId <= postCount; postId++) {
    if (existingPostIds.has(postId)) continue;
    const post = await board.posts(postId);
    if (!post.exists) continue;
    if (Number(post.supportCount) >= SUPPORT_THRESHOLD) {
      try {
        console.log(`\n안건 #${postId} "${post.title}" 지지 ${post.supportCount} — 피어리뷰 케이스 개시`);
        const tx = await peerReview.initiateCase(0 /* POLICY_PROPOSAL */, postId, post.author, "");
        await tx.wait();
      } catch (e) {
        console.error(`안건 #${postId} 케이스 개시 중 오류:`, e.message || e);
      }
    }
  }

  // 2) 에디터가 아직 배정되지 않은 모든 케이스(신규 + 지난 실행 보류분)에 대해 배정·초대 시도
  const pendingCases = await loadPendingEditorCases();
  for (const c of pendingCases) {
    try {
      await assignEditorsAndRecruit(c);
    } catch (e) {
      console.error(`case ${c.id} 에디터 배정 중 오류:`, e.message || e);
    }
  }

  console.log("\n=== 스캔 완료 ===");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { main };
