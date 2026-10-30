// scripts/deploy.js
//
// Deploys the full RegDAO suite and wires the roles between contracts.
//   npx hardhat run scripts/deploy.js --network sepolia
//
// Optional environment variables:
//   AGENT_ADDRESS   wallet of agent-service; receives PeerReview, ProposalBoard FCC and JoinRegistry agent roles
//   TEST_MODE=1     shortens Charter voting periods before governance is connected (test deployments only)
//
// The deployed addresses are written to deployments/<network>.json.

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function deploy(name, ...args) {
  const factory = await hre.ethers.getContractFactory(name);
  const c = await factory.deploy(...args);
  await c.waitForDeployment();
  console.log(`${name.padEnd(18)} ${await c.getAddress()}`);
  return c;
}

async function send(label, txPromise) {
  await (await txPromise).wait();
  console.log(`  ✓ ${label}`);
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const admin = deployer.address;
  console.log("배포 계정:", admin);
  console.log("잔액:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(admin)), "ETH");
  console.log("\n=== 배포 ===");

  const charter = await deploy("Charter", admin);
  const badge = await deploy("BadgeSBT", admin);
  const governance = await deploy("DAOGovernance", await badge.getAddress(), await charter.getAddress(), admin);
  const renderer = await deploy("BadgeRenderer");
  const rdao = await deploy("RDAOToken", admin);
  const board = await deploy("ProposalBoard", await badge.getAddress(), await rdao.getAddress(), admin);
  const peerReview = await deploy("PeerReview", await badge.getAddress(), await rdao.getAddress(), admin);
  const joinRegistry = await deploy("JoinRegistry", await badge.getAddress(), admin);
  const memberProfile = await deploy("MemberProfile", await badge.getAddress());
  const feeVault = await deploy("MembershipFeeVault", await rdao.getAddress(), await badge.getAddress(), admin, admin);
  const charterStakeVault = await deploy("CharterStakeVault", await rdao.getAddress(), await governance.getAddress(), admin);

  console.log("\n=== 권한 연결 ===");
  await send("BadgeSBT GOVERNANCE_ROLE -> DAOGovernance", badge.grantRole(await badge.GOVERNANCE_ROLE(), await governance.getAddress()));
  const POINTS_ROLE = await badge.POINTS_ROLE();
  await send("BadgeSBT POINTS_ROLE -> ProposalBoard", badge.grantRole(POINTS_ROLE, await board.getAddress()));
  await send("BadgeSBT POINTS_ROLE -> PeerReview", badge.grantRole(POINTS_ROLE, await peerReview.getAddress()));
  await send("BadgeSBT renderer", badge.setRenderer(await renderer.getAddress()));
  await send("RDAO MINTER_ROLE -> ProposalBoard (approval rewards)", rdao.setMinter(await board.getAddress(), true));
  await send("RDAO MINTER_ROLE -> PeerReview (panel rewards)", rdao.setMinter(await peerReview.getAddress(), true));
  await send("RDAO MINTER_ROLE -> CharterStakeVault", rdao.setMinter(await charterStakeVault.getAddress(), true));
  await send("ProposalBoard.peerReview", board.setPeerReview(await peerReview.getAddress()));
  await send("PeerReview.board", peerReview.setBoard(await board.getAddress()));

  if (process.env.AGENT_ADDRESS) {
    const agent = process.env.AGENT_ADDRESS;
    await send(`PeerReview agent ${agent}`, peerReview.setAgent(agent, true));
    await send(`ProposalBoard FCC agent ${agent}`, board.setFccAgent(agent, true));
    await send(`JoinRegistry agent ${agent}`, joinRegistry.setAgent(agent, true));
  }

  if (process.env.TEST_MODE === "1") {
    const shortPeriod = Number(process.env.TEST_VOTING_PERIOD_SECONDS || 60);
    await send(`TEST_MODE: 투표기간 ${shortPeriod}초`, charter.setVotingPeriodNormal(shortPeriod, 0));
    await send("TEST_MODE: 정관개정 투표기간", charter.setVotingPeriodAmendment(shortPeriod, 0));
  }
  await send("Charter governance -> DAOGovernance (이후 정관 변경은 투표로만 가능)", charter.setGovernance(await governance.getAddress()));

  const addresses = {
    network: hre.network.name,
    chainId: Number((await hre.ethers.provider.getNetwork()).chainId),
    deployedAt: new Date().toISOString(),
    contracts: {},
  };
  for (const [name, c] of Object.entries({
    Charter: charter, BadgeSBT: badge, DAOGovernance: governance, BadgeRenderer: renderer, RDAOToken: rdao,
    ProposalBoard: board, PeerReview: peerReview, JoinRegistry: joinRegistry, MemberProfile: memberProfile,
    MembershipFeeVault: feeVault, CharterStakeVault: charterStakeVault,
  })) {
    addresses.contracts[name] = await c.getAddress();
  }
  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${hre.network.name}.json`);
  fs.writeFileSync(outFile, JSON.stringify(addresses, null, 2) + "\n");
  console.log(`\n주소를 ${path.relative(process.cwd(), outFile)}에 저장했습니다.`);

  if (hre.network.name === "sepolia") {
    console.log("\nSepolia Etherscan:");
    for (const [name, a] of Object.entries(addresses.contracts)) console.log(`  ${name.padEnd(18)} https://sepolia.etherscan.io/address/${a}`);
  }
  if (!process.env.AGENT_ADDRESS) {
    console.log("\n⚠️  AGENT_ADDRESS를 지정하지 않아 admin이 에이전트·FCC 역할을 겸합니다. 별도 지갑을 쓰려면:");
    console.log("   peerReview.setAgent(agent, true); board.setFccAgent(agent, true); joinRegistry.setAgent(agent, true)");
  }
  console.log("\n⚠️  RDAO는 법정통화와 교환이 보장되지 않는 협회 내부 유틸리티 토큰입니다 (스테이블코인 아님).");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
