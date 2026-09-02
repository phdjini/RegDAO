// scripts/execute-proposal.js
//
// 목적: 투표 기간이 끝난 제안의 상태를 확인하고, 통과(SUCCEEDED)했으면 실행한다.
//
// 사용법:
//   PROPOSAL_ID=1 GOV_ADDRESS=0x... BADGE_ADDRESS=0x... npx hardhat run scripts/execute-proposal.js --network sepolia

const hre = require("hardhat");

const GOV_ADDRESS = "0x14Ae120a8b88638948901dfF0aB0A268dEaDd204";
const BADGE_ADDRESS = "0x69fC32d2385f3D01251f21D519B0410C6e03Feb4";
const PROPOSAL_ID = process.env.PROPOSAL_ID;

const STATE_NAMES = ["PENDING", "ACTIVE", "DEFEATED", "SUCCEEDED", "EXECUTED", "CANCELED"];

async function main() {
  if (!PROPOSAL_ID) throw new Error("PROPOSAL_ID 환경변수를 지정해주세요.");
  if (GOV_ADDRESS.includes("YOUR_GOVERNANCE") || BADGE_ADDRESS.includes("YOUR_BADGE")) {
    throw new Error("GOV_ADDRESS / BADGE_ADDRESS를 환경변수나 스크립트 상단에 설정해주세요.");
  }

  const governance = await hre.ethers.getContractAt("DAOGovernance", GOV_ADDRESS);
  const badge = await hre.ethers.getContractAt("BadgeSBT", BADGE_ADDRESS);

  const p = await governance.proposals(PROPOSAL_ID);
  const state = await governance.state(PROPOSAL_ID);
  console.log("제안 설명:", p.description);
  console.log("현재 상태:", STATE_NAMES[Number(state)]);
  console.log("찬성:", p.forVotes.toString(), " 반대:", p.againstVotes.toString(), " 기권:", p.abstainVotes.toString(), " 필요 정족수:", p.requiredQuorum.toString());

  if (Number(state) === 1) {
    console.log("\n⏳ 아직 투표 기간(ACTIVE)입니다. 종료 시각까지 기다려주세요.");
    console.log("종료 예정 시각(UTC):", new Date(Number(p.endTime) * 1000).toISOString());
    return;
  }

  if (Number(state) !== 3) {
    console.log("\n제안이 SUCCEEDED 상태가 아니라 집행할 수 없습니다. (정족수 미달 또는 부결)");
    return;
  }

  const pType = Number(p.pType); // 0=GENERAL, 1=SLASH, 2=CHARTER_AMENDMENT, 3=ACHIEVEMENT
  const slashTargetBefore = pType === 1 ? await badge.levelOf(p.slashTarget) : null;
  const achievementTargetBefore = pType === 3 ? await badge.levelOf(p.achievementTarget) : null;

  const tx = await governance.execute(PROPOSAL_ID);
  await tx.wait();
  console.log("\n✅ 제안 집행 완료!");

  if (slashTargetBefore !== null) {
    const isMember = await badge.isMember(p.slashTarget);
    console.log(`슬래싱 대상(${p.slashTarget}) 레벨: ${slashTargetBefore} -> `, isMember ? await badge.levelOf(p.slashTarget) : "배지 소각됨(자격 박탈)");
  }
  if (achievementTargetBefore !== null) {
    console.log(`성과 인증 대상(${p.achievementTarget}) 레벨: ${achievementTargetBefore} -> ${await badge.levelOf(p.achievementTarget)}`);
  }
  if (pType === 2) {
    console.log("정관 개정이 반영되었습니다. Charter 컨트랙트의 amendmentHistory에서 확인 가능합니다.");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
