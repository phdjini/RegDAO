// scripts/demo-governance.js
//
// 목적: bootstrap.js로 만든 멤버들을 이용해
//   1) newbie1에 대해 founder 3명이 지지(endorse) -> 자동 레벨업 확인
//   2) newbie2를 "어뷰저"로 가정하고 슬래싱 제안 생성 + 투표
// 까지 실행한다. 투표 종료(실제 3일 대기) 후 집행은 execute-proposal.js에서 별도 진행.
//
// 사용법:
//   BADGE_ADDRESS=0x... GOV_ADDRESS=0x... npx hardhat run scripts/demo-governance.js --network sepolia

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const MEMBERS_FILE = path.join(__dirname, "..", "members.json");
const BADGE_ADDRESS = "0x69fC32d2385f3D01251f21D519B0410C6e03Feb4";
const GOV_ADDRESS = "0x14Ae120a8b88638948901dfF0aB0A268dEaDd204";
const CHARTER_ADDRESS = "0x0A364511C8a6C26D8361488f91c985c80b037Af5";

async function main() {
  if (BADGE_ADDRESS.includes("YOUR_BADGE") || GOV_ADDRESS.includes("YOUR_GOVERNANCE") || CHARTER_ADDRESS.includes("YOUR_CHARTER")) {
    throw new Error("BADGE_ADDRESS / GOV_ADDRESS / CHARTER_ADDRESS를 환경변수나 스크립트 상단에 설정해주세요.");
  }
  if (!fs.existsSync(MEMBERS_FILE)) {
    throw new Error("members.json이 없습니다. 먼저 scripts/bootstrap.js를 실행하세요.");
  }

  const members = JSON.parse(fs.readFileSync(MEMBERS_FILE, "utf8"));
  const badge = await hre.ethers.getContractAt("BadgeSBT", BADGE_ADDRESS);
  const governance = await hre.ethers.getContractAt("DAOGovernance", GOV_ADDRESS);
  const charter = await hre.ethers.getContractAt("Charter", CHARTER_ADDRESS);

  const signerOf = (role) => new hre.ethers.Wallet(members[role].privateKey, hre.ethers.provider);

  const founder1 = signerOf("founder1");
  const founder2 = signerOf("founder2");
  const founder3 = signerOf("founder3");
  const newbie1 = members.newbie1.address;
  const newbie2 = members.newbie2.address;

  // ---------------------------------------------------------
  // 1) 지지 -> 자동 레벨업
  // ---------------------------------------------------------
  console.log("=== 1) 지지 기반 레벨업 테스트 (newbie1) ===");
  console.log("레벨업 전:", await badge.levelOf(newbie1));

  for (const [i, founder] of [founder1, founder2, founder3].entries()) {
    const tx = await badge.connect(founder).endorse(newbie1);
    await tx.wait();
    console.log(`  founder${i + 1}이 newbie1을 지지함`);
  }

  console.log("레벨업 후:", await badge.levelOf(newbie1));

  // ---------------------------------------------------------
  // 2) 슬래싱 제안 생성 + 투표
  // ---------------------------------------------------------
  console.log("\n=== 2) 슬래싱 제안: newbie2를 어뷰저로 가정 ===");

  const proposeTx = await governance
    .connect(founder1)
    .proposeSlash("데모: 어뷰징 신고 시나리오 테스트", newbie2, 1);
  const receipt = await proposeTx.wait();

  // ProposalCreated 이벤트에서 id 추출
  const event = receipt.logs
    .map((log) => {
      try {
        return governance.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((e) => e && e.name === "ProposalCreated");
  const proposalId = event.args.id;
  console.log("슬래싱 제안 생성 완료. Proposal ID:", proposalId.toString());

  // FOR = 1 (VoteChoice enum: NONE=0, FOR=1, AGAINST=2, ABSTAIN=3)
  for (const [i, founder] of [founder1, founder2, founder3].entries()) {
    const tx = await governance.connect(founder).castVote(proposalId, 1);
    await tx.wait();
    console.log(`  founder${i + 1} 찬성 투표 완료`);
  }

  const votingPeriod = await charter.votingPeriodNormal();
  const quorum = await charter.quorumNormal();
  console.log(`\n투표 기간: ${votingPeriod.toString()}초 · 필요 정족수: ${quorum.toString()}`);
  console.log("투표 기간이 끝난 후 아래 명령으로 집행하세요:");
  console.log(
    `PROPOSAL_ID=${proposalId} npx hardhat run scripts/execute-proposal.js --network sepolia`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
