// scripts/deploy-renderer.js
//
// 이미 배포된 BadgeSBT는 그대로 두고, BadgeRenderer만 새로 배포해서 연결한다.
// (전체 시스템을 재배포할 필요 없이 배지 아트워크만 추가/교체할 때 사용)
//
// 사용법:
//   BADGE_ADDRESS=0x... npx hardhat run scripts/deploy-renderer.js --network sepolia

const hre = require("hardhat");

const BADGE_ADDRESS = process.env.BADGE_ADDRESS || "0xYOUR_BADGE_SBT_ADDRESS";

async function main() {
  if (BADGE_ADDRESS.includes("YOUR_BADGE")) {
    throw new Error("BADGE_ADDRESS를 환경변수나 스크립트 상단에 설정해주세요.");
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log("배포 계정:", deployer.address);

  const BadgeRenderer = await hre.ethers.getContractFactory("BadgeRenderer");
  const renderer = await BadgeRenderer.deploy();
  await renderer.waitForDeployment();
  const rendererAddr = await renderer.getAddress();
  console.log("BadgeRenderer 배포 완료:", rendererAddr);

  const badge = await hre.ethers.getContractAt("BadgeSBT", BADGE_ADDRESS);
  const tx = await badge.setRenderer(rendererAddr);
  await tx.wait();
  console.log("BadgeSBT.renderer 연결 완료");

  console.log(`\nSepolia Etherscan: https://sepolia.etherscan.io/address/${rendererAddr}`);
  console.log("메타마스크에서 배지 NFT를 다시 확인해보세요 (새로고침 또는 재추가 필요할 수 있음).");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
