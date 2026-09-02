// scripts/deploy-join-registry.js
//
// 이미 배포된 BadgeSBT/DAOGovernance는 그대로 두고 JoinRegistry만 추가로 배포한다.
//
// 사용법:
//   npx hardhat run scripts/deploy-join-registry.js --network sepolia

const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("배포 계정:", deployer.address);

  const JoinRegistry = await hre.ethers.getContractFactory("JoinRegistry");
  const registry = await JoinRegistry.deploy(deployer.address);
  await registry.waitForDeployment();

  const addr = await registry.getAddress();
  console.log("JoinRegistry 배포 완료:", addr);
  console.log(`\nSepolia Etherscan: https://sepolia.etherscan.io/address/${addr}`);
  console.log("\n이 주소를 대시보드의 'JoinRegistry 주소' 입력란에 넣어주세요.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
