require("dotenv").config();
const { joinRegistry, profile, badge } = require("./chain");
const { sendJoinReviewerAssignedEmail } = require("./email");
const { sendSms } = require("./sms");

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

function pickRandom(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

async function assignPendingApplications() {
  const count = Number(await joinRegistry.applicationCount());
  const minTier = Number(await joinRegistry.minApproverTier());

  const profiledMembers = await loadAllProfiledMembers();
  const founderPool = [];
  for (const m of profiledMembers) {
    const tier = Number(await badge.tierOf(m.address));
    if (tier >= minTier) founderPool.push(m);
  }

  if (founderPool.length === 0) {
    console.warn(`창립 등급(Tier ${minTier}) 이상 프로필 등록 회원이 없어 배정을 진행할 수 없습니다.`);
    return;
  }

  for (let id = 1; id <= count; id++) {
    const a = await joinRegistry.applications(id);
    if (a.approved || a.rejected) continue;
    if (a.assignedReviewer !== "0x0000000000000000000000000000000000000000") continue; // 이미 배정됨

    const chosen = pickRandom(founderPool);
    console.log(`[application ${id}] 무작위 심사담당자 배정: ${chosen.address}`);

    const tx = await joinRegistry.assignReviewer(id, chosen.address);
    await tx.wait();

    if (chosen.email) {
      await sendJoinReviewerAssignedEmail({ to: chosen.email, applicationId: id, applicantOrg: a.org });
    } else {
      console.warn(`[application ${id}] ${chosen.address}의 이메일이 프로필에 없어 메일을 보내지 못했습니다.`);
    }
    if (chosen.phone) {
      await sendSms(chosen.phone, `[RegDAO] 가입 신청 #${id} 심사 담당자로 배정되었습니다. 대시보드에서 확인해주세요.`);
    } else {
      console.warn(`[application ${id}] ${chosen.address}의 전화번호가 프로필에 없어 SMS를 보내지 못했습니다.`);
    }
  }
}

async function main() {
  console.log("=== 가입 신청 심사담당자 무작위 배정 실행 ===", new Date().toISOString());
  await assignPendingApplications();
  console.log("=== 완료 ===");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { main };
