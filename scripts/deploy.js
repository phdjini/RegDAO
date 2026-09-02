const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("배포 계정:", deployer.address);
  console.log("잔액:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH/POL");

  // 1. Charter 배포 (admin = deployer, 아직 governance 미연결 상태)
  const Charter = await hre.ethers.getContractFactory("Charter");
  const charter = await Charter.deploy(deployer.address);
  await charter.waitForDeployment();
  console.log("Charter 배포 완료:", await charter.getAddress());

  // 2. BadgeSBT 배포
  const BadgeSBT = await hre.ethers.getContractFactory("BadgeSBT");
  const badge = await BadgeSBT.deploy(deployer.address);
  await badge.waitForDeployment();
  console.log("BadgeSBT 배포 완료:", await badge.getAddress());

  // 3. DAOGovernance 배포 (Charter 참조)
  const DAOGovernance = await hre.ethers.getContractFactory("DAOGovernance");
  const governance = await DAOGovernance.deploy(await badge.getAddress(), await charter.getAddress(), deployer.address);
  await governance.waitForDeployment();
  console.log("DAOGovernance 배포 완료:", await governance.getAddress());

  // 4. 권한 연결
  const GOVERNANCE_ROLE = await badge.GOVERNANCE_ROLE();
  await (await badge.grantRole(GOVERNANCE_ROLE, await governance.getAddress())).wait();
  console.log("GOVERNANCE_ROLE 부여 완료 (DAOGovernance -> BadgeSBT.slash/levelUpByGovernance 호출 가능)");

  // 4.5. (테스트 전용) governance 연결 전에만 admin이 투표기간을 직접 조정할 수 있다.
  //      TEST_MODE=1 로 실행하면 정족수 도달 여부만 빠르게 확인할 수 있도록 투표기간을 짧게 설정한다.
  //      실제 운영 배포에서는 TEST_MODE를 절대 켜지 마세요.
  if (process.env.TEST_MODE === "1") {
    const shortPeriod = Number(process.env.TEST_VOTING_PERIOD_SECONDS || 60);
    await (await charter.setVotingPeriodNormal(shortPeriod, 0)).wait();
    await (await charter.setVotingPeriodAmendment(shortPeriod, 0)).wait();
    console.log(`⚠️  TEST_MODE: 투표기간을 ${shortPeriod}초로 단축했습니다 (테스트 전용, 운영 배포 시 사용 금지).`);
  }

  await (await charter.setGovernance(await governance.getAddress())).wait();
  console.log("Charter governance 연결 완료 (이제부터 정관 개정은 DAOGovernance 투표를 통해서만 가능)");

  // 5. BadgeRenderer 배포 및 연결 (온체인 SVG 배지 아트워크)
  const BadgeRenderer = await hre.ethers.getContractFactory("BadgeRenderer");
  const renderer = await BadgeRenderer.deploy();
  await renderer.waitForDeployment();
  console.log("BadgeRenderer 배포 완료:", await renderer.getAddress());

  await (await badge.setRenderer(await renderer.getAddress())).wait();
  console.log("BadgeSBT.renderer 연결 완료 (메타마스크 NFT 탭에서 등급별 문장 배지 이미지 표시)");

  // 6. ProposalBoard 배포 및 연결 (정책제안 게시판 -> 포인트 반영 권한)
  const ProposalBoard = await hre.ethers.getContractFactory("ProposalBoard");
  const board = await ProposalBoard.deploy(await badge.getAddress(), deployer.address);
  await board.waitForDeployment();
  console.log("ProposalBoard 배포 완료:", await board.getAddress());

  const POINTS_ROLE = await badge.POINTS_ROLE();
  await (await badge.grantRole(POINTS_ROLE, await board.getAddress())).wait();
  console.log("POINTS_ROLE 부여 완료 (ProposalBoard -> BadgeSBT.addPoints 호출 가능)");

  // 7. JoinRegistry 배포 (BadgeSBT 참조 — 이미 회원인 주소는 신청 자체가 온체인에서 거부됨)
  const JoinRegistry = await hre.ethers.getContractFactory("JoinRegistry");
  const joinRegistry = await JoinRegistry.deploy(await badge.getAddress(), deployer.address);
  await joinRegistry.waitForDeployment();
  console.log("JoinRegistry 배포 완료:", await joinRegistry.getAddress());

  // 8. MemberProfile 배포 (관심분야/소개 — 피어리뷰 매칭용)
  const MemberProfile = await hre.ethers.getContractFactory("MemberProfile");
  const memberProfile = await MemberProfile.deploy(await badge.getAddress());
  await memberProfile.waitForDeployment();
  console.log("MemberProfile 배포 완료:", await memberProfile.getAddress());

  // 9. PeerReview 배포 및 연결 (피어리뷰 프로세스 -> 포인트 반영 권한)
  const PeerReview = await hre.ethers.getContractFactory("PeerReview");
  const peerReview = await PeerReview.deploy(await badge.getAddress(), deployer.address);
  await peerReview.waitForDeployment();
  console.log("PeerReview 배포 완료:", await peerReview.getAddress());

  await (await badge.grantRole(POINTS_ROLE, await peerReview.getAddress())).wait();
  console.log("POINTS_ROLE 부여 완료 (PeerReview -> BadgeSBT.addPoints 호출 가능)");

  console.log("\n=== 배포 요약 ===");
  console.log("Charter        :", await charter.getAddress());
  console.log("BadgeSBT       :", await badge.getAddress());
  console.log("DAOGovernance  :", await governance.getAddress());
  console.log("BadgeRenderer  :", await renderer.getAddress());
  console.log("ProposalBoard  :", await board.getAddress());
  console.log("JoinRegistry   :", await joinRegistry.getAddress());
  console.log("MemberProfile  :", await memberProfile.getAddress());
  console.log("PeerReview     :", await peerReview.getAddress());
  console.log("Admin/Registrar:", deployer.address);
  console.log("\nSepolia Etherscan:");
  console.log(`  https://sepolia.etherscan.io/address/${await charter.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await badge.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await governance.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await renderer.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await board.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await joinRegistry.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await memberProfile.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await peerReview.getAddress()}`);
  console.log("\n⚠️  참고: Charter.setGovernance()를 호출한 순간부터 정족수/투표기간/정관 조항의");
  console.log("   변경 권한이 admin에서 DAOGovernance(투표)로 완전히 넘어갑니다. 필요한 초기값");
  console.log("   (예: 테스트용 짧은 투표기간)은 setGovernance() 호출 이전에 admin이 미리 조정해두세요.");
  console.log("\n⚠️  참고: agent-service를 별도 지갑으로 운영하려면 아래를 추가로 호출해야 합니다.");
  console.log("   await peerReview.setAgent('0x에이전트지갑주소', true)");
  console.log("   await joinRegistry.setAgent('0x에이전트지갑주소', true)  // 가입 승인자 무작위 배정용");

  // 10. RDAOToken 배포 (협회 내부 유틸리티 토큰 — 원화 스테이블코인 아님)
  const RDAOToken = await hre.ethers.getContractFactory("RDAOToken");
  const rdao = await RDAOToken.deploy(deployer.address);
  await rdao.waitForDeployment();
  console.log("\nRDAOToken 배포 완료:", await rdao.getAddress());

  // 11. MembershipFeeVault 배포 (연회비·행사비 결제)
  const MembershipFeeVault = await hre.ethers.getContractFactory("MembershipFeeVault");
  const feeVault = await MembershipFeeVault.deploy(
    await rdao.getAddress(), await badge.getAddress(), deployer.address, deployer.address
  );
  await feeVault.waitForDeployment();
  console.log("MembershipFeeVault 배포 완료:", await feeVault.getAddress());

  // 12. ProposalStakeVault 배포 (제안마당 글쓰기 예치금)
  const ProposalStakeVault = await hre.ethers.getContractFactory("ProposalStakeVault");
  const boardStakeVault = await ProposalStakeVault.deploy(
    await rdao.getAddress(), await board.getAddress(), await peerReview.getAddress(), deployer.address
  );
  await boardStakeVault.waitForDeployment();
  console.log("ProposalStakeVault 배포 완료:", await boardStakeVault.getAddress());

  // 13. CharterStakeVault 배포 (정관개정 제안 예치금)
  const CharterStakeVault = await hre.ethers.getContractFactory("CharterStakeVault");
  const charterStakeVault = await CharterStakeVault.deploy(
    await rdao.getAddress(), await governance.getAddress(), deployer.address
  );
  await charterStakeVault.waitForDeployment();
  console.log("CharterStakeVault 배포 완료:", await charterStakeVault.getAddress());

  // RDAO 발행 권한(MINTER_ROLE) 연결 — 보너스 지급을 위해 두 Vault도 발행 권한 필요
  await (await rdao.setMinter(await boardStakeVault.getAddress(), true)).wait();
  await (await rdao.setMinter(await charterStakeVault.getAddress(), true)).wait();
  await (await rdao.setMinter(await peerReview.getAddress(), true)).wait();
  console.log("RDAOToken MINTER_ROLE 부여 완료 (ProposalStakeVault / CharterStakeVault / PeerReview)");

  // PeerReview가 발행 시 RDAO 보상을 지급하도록 연결
  await (await peerReview.setRdaoToken(await rdao.getAddress())).wait();
  console.log("PeerReview.rdaoToken 연결 완료 (발행 시 에디터·리뷰어에게 RDAO 자동 지급)");

  console.log("\n=== RDAO 관련 배포 요약 ===");
  console.log("RDAOToken          :", await rdao.getAddress());
  console.log("MembershipFeeVault :", await feeVault.getAddress());
  console.log("ProposalStakeVault :", await boardStakeVault.getAddress());
  console.log("CharterStakeVault  :", await charterStakeVault.getAddress());
  console.log(`  https://sepolia.etherscan.io/address/${await rdao.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await feeVault.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await boardStakeVault.getAddress()}`);
  console.log(`  https://sepolia.etherscan.io/address/${await charterStakeVault.getAddress()}`);
  console.log("\n⚠️  참고: RDAO는 원화나 그 어떤 법정통화와도 교환이 보장되지 않는 협회 내부");
  console.log("   유틸리티 토큰입니다 (스테이블코인 아님). 회비·행사비 결제, 제안 예치금(스테이킹)");
  console.log("   용도로만 설계되어 있습니다.");
  console.log("\n⚠️  참고: 제안마당 글쓰기 시 최소 등급 요건은 현재 0(전체 허용, 테스트 단계)입니다.");
  console.log("   정식 운영 전환 시 board.setMinPostTier(원하는등급)으로 조정하세요.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
