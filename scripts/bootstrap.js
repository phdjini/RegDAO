// scripts/bootstrap.js
//
// 목적: 데모/테스트용 멤버 지갑을 자동으로 여러 개 생성하고,
//       배포자(admin) 지갑에서 가스비를 소량씩 나눠준 뒤,
//       BadgeSBT에 창립 멤버(Lv3) + 신규 회원(Lv1) 배지를 발급한다.
//
// 사용법:
//   BADGE_ADDRESS=0x... npx hardhat run scripts/bootstrap.js --network sepolia
//
// 결과: members.json 파일에 생성된 지갑 주소/개인키/역할이 저장됨
//       (테스트 전용 지갑이므로 개인키가 파일에 그대로 저장됩니다.
//        실제 자산이 있는 지갑의 개인키는 절대 이렇게 다루지 마세요.)

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const MEMBERS_FILE = path.join(__dirname, "..", "members.json");

// 배포된 BadgeSBT 주소 (환경변수 우선, 없으면 아래 기본값을 직접 수정)
const BADGE_ADDRESS = "0x69fC32d2385f3D01251f21D519B0410C6e03Feb4";

// 부트스트랩할 멤버 구성: 창립 대표단 3명(Lv3) + 신규 지원자 2명(Lv1)
const MEMBER_PLAN = [
  { role: "founder1", level: 3 },
  { role: "founder2", level: 3 },
  { role: "founder3", level: 3 },
  { role: "newbie1", level: 1 },
  { role: "newbie2", level: 1 },
];

const GAS_FUNDING_ETH = "0.01"; // 각 멤버 지갑에 보내줄 가스비 (테스트넷 ETH)

async function main() {
  if (BADGE_ADDRESS.includes("YOUR_BADGE")) {
    throw new Error("BADGE_ADDRESS를 환경변수나 스크립트 상단에 설정해주세요.");
  }

  const [admin] = await hre.ethers.getSigners();
  console.log("관리자(registrar) 계정:", admin.address);

  const badge = await hre.ethers.getContractAt("BadgeSBT", BADGE_ADDRESS);

  // 1) 멤버 지갑 생성 + 가스비 지원
  const members = {};
  for (const plan of MEMBER_PLAN) {
    const wallet = hre.ethers.Wallet.createRandom().connect(hre.ethers.provider);
    members[plan.role] = {
      address: wallet.address,
      privateKey: wallet.privateKey,
      level: plan.level,
    };

    console.log(`\n[${plan.role}] 새 지갑 생성: ${wallet.address}`);

    const fundTx = await admin.sendTransaction({
      to: wallet.address,
      value: hre.ethers.parseEther(GAS_FUNDING_ETH),
    });
    await fundTx.wait();
    console.log(`  가스비 ${GAS_FUNDING_ETH} ETH 전송 완료`);

    const mintTx = await badge.mintAt(wallet.address, plan.level);
    await mintTx.wait();
    console.log(`  배지 발급 완료 (Level ${plan.level})`);
  }

  fs.writeFileSync(MEMBERS_FILE, JSON.stringify(members, null, 2));
  console.log(`\n✅ 부트스트랩 완료. 지갑 정보 저장: ${MEMBERS_FILE}`);
  console.log("다음: npx hardhat run scripts/demo-governance.js --network sepolia");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
