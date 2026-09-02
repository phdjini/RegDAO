// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDAOGovernanceRead {
    function proposals(uint256 id) external view returns (
        uint256 pid, address proposer, uint8 pType, string memory description, address target, uint256 value,
        bytes memory data, address slashTarget, uint8 slashLevels, address achievementTarget, uint8 achievementLevel,
        uint256 startTime, uint256 endTime, uint256 requiredQuorum, uint256 forVotes, uint256 againstVotes,
        uint256 abstainVotes, bool executed, bool canceled
    );
    function state(uint256 id) external view returns (uint8);
}

/**
 * @title CharterStakeVault
 * @notice 정관개정 제안 시 RDAO 예치를 요구하여 신중한 제안만 올라오도록 유도한다.
 *         제안이 가결·집행(Executed)되면 예치금과 보너스를 돌려받고, 부결(Defeated)되면
 *         예치금의 일부가 소각된다. 취소(Canceled)된 경우는 페널티 없이 전액 반환한다.
 *
 *         DAOGovernance.state(): 0=Pending 1=Active 2=Defeated 3=Succeeded 4=Executed 5=Canceled
 */
contract CharterStakeVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable rdao;
    ERC20Burnable public immutable rdaoBurnable;
    IDAOGovernanceRead public immutable governance;
    address public admin;

    uint256 public stakeAmount = 100 * 1e18; // 정관개정 제안 1건당 예치금 (기본 100 RDAO, 일반 제안보다 높음)
    uint256 public bonusBps = 3000;          // 가결 시 보너스 (기본 30%)
    // 부결(Defeated) 시 소각 없이 예치금 전액 반환 — "완화형" 정책.
    // 논쟁적이거나 시의성이 안 맞아 부결된 제안까지 페널티를 주면 참여 자체가 위축될
    // 수 있어, 초기에는 소각을 두지 않는다. 실제 어뷰징이 관측되면 관리자가 조정한다.
    uint256 public burnBps = 0;              // 부결 시 소각 비율 (기본 0%, 필요 시 관리자가 조정)

    enum StakeStatus { NONE, STAKED, RESOLVED }
    struct Stake {
        address staker;
        uint256 amount;
        StakeStatus status;
    }
    mapping(uint256 => Stake) public stakes; // proposalId => Stake

    event Staked(uint256 indexed proposalId, address indexed staker, uint256 amount);
    event Resolved(uint256 indexed proposalId, uint8 outcome, uint256 refunded, uint256 burned, uint256 bonus);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address rdaoToken, address governanceContract, address admin_) {
        rdao = IERC20(rdaoToken);
        rdaoBurnable = ERC20Burnable(rdaoToken);
        governance = IDAOGovernanceRead(governanceContract);
        admin = admin_;
    }

    function stake(uint256 proposalId) external {
        (, address proposer, uint8 pType, , , , , , , , , , , , , , , , ) = governance.proposals(proposalId);
        require(pType == 2, "CharterStakeVault: not a charter amendment proposal");
        require(proposer == msg.sender, "CharterStakeVault: only the proposer can stake");
        require(stakes[proposalId].status == StakeStatus.NONE, "CharterStakeVault: already staked");

        stakes[proposalId] = Stake({ staker: msg.sender, amount: stakeAmount, status: StakeStatus.STAKED });
        rdao.safeTransferFrom(msg.sender, address(this), stakeAmount);
        emit Staked(proposalId, msg.sender, stakeAmount);
    }

    function resolve(uint256 proposalId) external {
        Stake storage s = stakes[proposalId];
        require(s.status == StakeStatus.STAKED, "CharterStakeVault: no active stake");

        uint8 st = governance.state(proposalId);
        require(st == 2 || st == 4 || st == 5, "CharterStakeVault: proposal not yet finally decided");

        s.status = StakeStatus.RESOLVED;

        if (st == 4) {
            // Executed: 전액 반환 + 보너스
            uint256 bonus = (s.amount * bonusBps) / 10000;
            rdao.safeTransfer(s.staker, s.amount);
            (bool ok, ) = address(rdao).call(abi.encodeWithSignature("mint(address,uint256)", s.staker, bonus));
            require(ok, "CharterStakeVault: bonus mint failed (vault must have MINTER_ROLE on RDAOToken)");
            emit Resolved(proposalId, st, s.amount, 0, bonus);
        } else if (st == 2) {
            // Defeated: 일부 소각
            uint256 burnAmt = (s.amount * burnBps) / 10000;
            uint256 refundAmt = s.amount - burnAmt;
            if (burnAmt > 0) rdaoBurnable.burn(burnAmt);
            if (refundAmt > 0) rdao.safeTransfer(s.staker, refundAmt);
            emit Resolved(proposalId, st, refundAmt, burnAmt, 0);
        } else {
            // Canceled: 페널티 없이 전액 반환
            rdao.safeTransfer(s.staker, s.amount);
            emit Resolved(proposalId, st, s.amount, 0, 0);
        }
    }

    function setStakeAmount(uint256 v) external onlyAdmin { stakeAmount = v; }
    function setBonusBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); bonusBps = v; }
    function setBurnBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); burnBps = v; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
