// scripts/quick-test.js
//
// 목적: 투표 기간을 짧게(기본 60초) 바꾼 뒤, 새로운 테스트용 슬래싱 제안을 만들고
//       founder 3명이 투표까지 마친다. 이후 60초 기다렸다가 execute-proposal.js로
//       바로 집행해서 전체 흐름(제안->투표->집행->슬래싱 반영)을 눈으로 확인할 수 있다.
//
// 사용법: 아래 BADGE_ADDRESS / GOV_ADDRESS를 실제 배포 주소로 수정한 뒤
//   npx hardhat run scripts/quick-test.js --network sepolia

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const MEMBERS_FILE = path.join(__dirname, "..", "members.json");

// 실제 배포 주소로 교체하세요
const BADGE_ADDRESS = "0x실제BadgeSBT주소";
const GOV_ADDRESS = "0x실제DAOGovernance주소";

const SHORT_VOTING_PERIOD_SECONDS = 60; // 테스트용 60초

async function main() {
  if (!fs.existsSync(MEMBERS_FILE)) {
    throw new Error("members.json이 없습니다. 먼저 scripts/bootstrap.js를 실행하세요.");
  }
  const members = JSON.parse(fs.readFileSync(MEMBERS_FILE, "utf8"));

  const [admin] = await hre.ethers.getSigners();
  const governance = await hre.ethers.getContractAt("DAOGovernance", GOV_ADDRESS);

  // 1) 관리자 권한으로 투표 기간 단축 (다음에 생성되는 제안부터 적용)
  console.log("현재 투표 기간(초):", (await governance.votingPeriod()).toString());
  const setTx = await governance.connect(admin).setVotingPeriod(SHORT_VOTING_PERIOD_SECONDS);
  await setTx.wait();
  console.log(`투표 기간을 ${SHORT_VOTING_PERIOD_SECONDS}초로 단축 완료`);

  // 2) 새 테스트 제안 생성 (founder1이 제안)
  const signerOf = (role) => new hre.ethers.Wallet(members[role].privateKey, hre.ethers.provider);
  const founder1 = signerOf("founder1");
  const founder2 = signerOf("founder2");
  const founder3 = signerOf("founder3");
  const newbie2 = members.newbie2.address;

  const proposeTx = await governance
    .connect(founder1)
    .proposeSlash("빠른 테스트용 제안: 전체 흐름 검증", newbie2, 1);
  const receipt = await proposeTx.wait();

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
  console.log("\n새 테스트 제안 생성 완료. Proposal ID:", proposalId.toString());

  // 3) founder 3명 찬성 투표
  for (const [i, founder] of [founder1, founder2, founder3].entries()) {
    const tx = await governance.connect(founder).castVote(proposalId, 1);
    await tx.wait();
    console.log(`  founder${i + 1} 찬성 투표 완료`);
  }

  console.log(`\n⏳ ${SHORT_VOTING_PERIOD_SECONDS}초 후 아래 명령으로 집행하세요:`);
  console.log(`PROPOSAL_ID=${proposalId} npx hardhat run scripts/execute-proposal.js --network sepolia`);
  console.log("\n(execute-proposal.js 상단의 BADGE_ADDRESS / GOV_ADDRESS도 동일하게 설정되어 있어야 합니다)");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
