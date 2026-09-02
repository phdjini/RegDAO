const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("DAO Badge & Governance System", function () {
  let badge, governance, admin, f1, f2, f3, newbie, abuser, voter1, voter2;

  beforeEach(async function () {
    [admin, f1, f2, f3, newbie, abuser, voter1, voter2] = await ethers.getSigners();

    const BadgeSBT = await ethers.getContractFactory("BadgeSBT");
    badge = await BadgeSBT.deploy(admin.address);
    await badge.waitForDeployment();

    const DAOGovernance = await ethers.getContractFactory("DAOGovernance");
    governance = await DAOGovernance.deploy(await badge.getAddress(), admin.address);
    await governance.waitForDeployment();

    const GOVERNANCE_ROLE = await badge.GOVERNANCE_ROLE();
    await badge.grantRole(GOVERNANCE_ROLE, await governance.getAddress());

    // 창립 멤버(민+관 대표) 3명을 Level 3(Council)로 부트스트랩
    await badge.mintAt(f1.address, 3);
    await badge.mintAt(f2.address, 3);
    await badge.mintAt(f3.address, 3);

    // 신규 지원자 / 어뷰저 / 일반 투표자는 Level 1로 발급
    await badge.mint(newbie.address);
    await badge.mint(abuser.address);
    await badge.mint(voter1.address);
    await badge.mint(voter2.address);

    await badge.setEndorseCooldown(0); // 테스트 편의상 쿨다운 제거
  });

  it("창립 멤버는 지정된 레벨로, 신규 회원은 Level 1로 발급된다", async function () {
    expect(await badge.levelOf(f1.address)).to.equal(3);
    expect(await badge.levelOf(newbie.address)).to.equal(1);
  });

  it("Level 1은 다른 사람을 지지할 수 없다", async function () {
    await expect(badge.connect(newbie).endorse(abuser.address)).to.be.revertedWith(
      "endorser must be Member+ (Lv2 min)"
    );
  });

  it("Level 2+ 멤버 3명의 지지를 받으면 Level 1 -> 2로 자동 레벨업한다", async function () {
    // threshold(level 1 -> 2) 기본값 = 3
    await badge.connect(f1).endorse(newbie.address);
    await badge.connect(f2).endorse(newbie.address);
    expect(await badge.levelOf(newbie.address)).to.equal(1); // 아직 2명

    await badge.connect(f3).endorse(newbie.address);
    expect(await badge.levelOf(newbie.address)).to.equal(2); // 3명째에 레벨업
  });

  it("동일인의 중복 지지는 카운트되지 않는다", async function () {
    await badge.connect(f1).endorse(newbie.address);
    await expect(badge.connect(f1).endorse(newbie.address)).to.be.revertedWith(
      "already endorsed at this level"
    );
  });

  it("자기 자신은 지지할 수 없다", async function () {
    await expect(badge.connect(f1).endorse(f1.address)).to.be.revertedWith("cannot self-endorse");
  });

  it("Level 2 미만은 거버넌스 제안을 생성할 수 없다", async function () {
    await expect(
      governance.connect(newbie).proposeSlash("어뷰징", abuser.address, 1)
    ).to.be.revertedWith("insufficient badge level to propose");
  });

  it("슬래싱 통합 시나리오: 제안 -> 투표 -> 정족수 충족 -> 실행 -> 레벨 강등", async function () {
    // f1이 abuser(Level 1)에 대한 슬래싱 제안 생성 (강등폭 1레벨 -> 0이 되어 배지 소각)
    const tx = await governance.connect(f1).proposeSlash("어뷰징 신고: 봇 계정으로 다수 지지 조작", abuser.address, 1);
    const receipt = await tx.wait();
    const proposalId = 1n;

    // f1, f2, f3(각 Level 3) 이 찬성 투표 → 투표력 합 = 9 (quorum 10 미달이면 실패하므로 voter1도 참여)
    await governance.connect(f1).castVote(proposalId, 1); // FOR
    await governance.connect(f2).castVote(proposalId, 1); // FOR
    await governance.connect(f3).castVote(proposalId, 1); // FOR
    await governance.connect(voter1).castVote(proposalId, 1); // FOR, Level 1 => +1

    // 투표 기간 종료까지 시간 이동
    await time.increase(3 * 24 * 60 * 60 + 1);

    expect(await governance.state(proposalId)).to.equal(3); // SUCCEEDED

    await governance.execute(proposalId);

    // abuser는 Level 1 - 1 = 0 => 배지 완전 소각(자격 박탈)
    expect(await badge.isMember(abuser.address)).to.equal(false);
  });

  it("배지는 양도할 수 없다 (soulbound)", async function () {
    const tokenId = await badge.tokenIdOf(f1.address);
    await expect(
      badge.connect(f1).transferFrom(f1.address, f2.address, tokenId)
    ).to.be.revertedWith("BadgeSBT: soulbound, non-transferable");
  });

  it("정족수 미달 시 제안은 부결(DEFEATED)된다", async function () {
    const tx = await governance.connect(f1).proposeSlash("경미한 신고", abuser.address, 1);
    await tx.wait();
    const proposalId = 1n;

    await governance.connect(f1).castVote(proposalId, 1); // FOR, power=3 (quorum=10 미달)
    await time.increase(3 * 24 * 60 * 60 + 1);

    expect(await governance.state(proposalId)).to.equal(2); // DEFEATED
  });
});
