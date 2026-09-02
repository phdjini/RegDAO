// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IProposalBoardRead {
    function posts(uint256 id) external view returns (
        uint256 postId, address author, uint8 category, string memory title, string memory content,
        string memory attachmentURI, uint64 createdAt, uint256 supportCount, uint256 opposeCount, bool exists
    );
}

interface IPeerReviewRead {
    function cases(uint256 id) external view returns (
        uint256 caseId, uint8 caseType, uint256 sourcePostId, address claimant, string memory description,
        address chiefEditor, address coEditor, uint8 status, uint64 createdAt, uint64 publishedAt,
        uint256 approveCount, bool adopted, string memory finalTitle, string memory finalDocumentURI, string memory finalSummary
    );
}

/**
 * @title ProposalStakeVault
 * @notice 제안마당에 글을 올릴 때 RDAO를 예치(스테이킹)하도록 하여 무분별한 저품질 제안을
 *         억제하는 어뷰징 방지 장치. 그 제안이 동료검토를 거쳐 "의안상정"되면 예치금을
 *         보너스와 함께 돌려받고, "의안상정보류"(부결)되면 예치금 일부가 소각된다.
 *
 *         스테이킹은 선택이 아니라, 제안 작성자가 이 컨트랙트를 통해 별도로 예치해야
 *         활성화된다 (게시글 자체는 ProposalBoard에 그대로 유지). 운영기관이 스테이킹을
 *         필수로 요구할지 여부는 UI/정책으로 안내한다.
 */
contract ProposalStakeVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable rdao;
    ERC20Burnable public immutable rdaoBurnable;
    IProposalBoardRead public immutable board;
    IPeerReviewRead public immutable peerReview;
    address public admin;

    uint256 public stakeAmount = 20 * 1e18;   // 제안 1건당 예치금 (기본 20 RDAO)
    uint256 public bonusBps = 2000;           // 통과 시 보너스 (기본 20%, basis points)
    // 부결(의안상정보류) 시 소각 없이 예치금 전액 반환 — "완화형" 정책.
    // 초기에는 참여 위축을 막기 위해 페널티를 두지 않으며, 실제 어뷰징이 관측되면
    // burnBps를 관리자가 설정해 소각형으로 전환할 수 있는 여지만 남겨둔다.
    uint256 public burnBps = 0;               // 부결 시 소각 비율 (기본 0%, 필요 시 관리자가 조정)

    enum StakeStatus { NONE, STAKED, RESOLVED_REFUNDED, RESOLVED_BURNED }

    struct Stake {
        address staker;
        uint256 amount;
        StakeStatus status;
    }
    mapping(uint256 => Stake) public stakes; // postId => Stake

    event Staked(uint256 indexed postId, address indexed staker, uint256 amount);
    event Resolved(uint256 indexed postId, bool adopted, uint256 refunded, uint256 burned, uint256 bonus);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address rdaoToken, address boardContract, address peerReviewContract, address admin_) {
        rdao = IERC20(rdaoToken);
        rdaoBurnable = ERC20Burnable(rdaoToken);
        board = IProposalBoardRead(boardContract);
        peerReview = IPeerReviewRead(peerReviewContract);
        admin = admin_;
    }

    /// @notice 제안 작성자가 본인 글에 대해 예치금을 건다. 게시글 작성자 본인만 가능하다.
    function stake(uint256 postId) external {
        (, address author, , , , , , , , bool exists) = board.posts(postId);
        require(exists, "ProposalStakeVault: post does not exist");
        require(author == msg.sender, "ProposalStakeVault: only the post author can stake");
        require(stakes[postId].status == StakeStatus.NONE, "ProposalStakeVault: already staked for this post");

        stakes[postId] = Stake({ staker: msg.sender, amount: stakeAmount, status: StakeStatus.STAKED });
        rdao.safeTransferFrom(msg.sender, address(this), stakeAmount);
        emit Staked(postId, msg.sender, stakeAmount);
    }

    /// @notice 동료검토 결과가 확정된 뒤 누구나 호출해 예치금을 정산할 수 있다 (트러스트리스 정산).
    ///         caseId는 해당 postId를 원본으로 하는 PeerReview 케이스여야 한다.
    function resolve(uint256 postId, uint256 caseId) external {
        Stake storage s = stakes[postId];
        require(s.status == StakeStatus.STAKED, "ProposalStakeVault: no active stake to resolve");

        (, uint8 caseType, uint256 sourcePostId, , , , , uint8 status, , , , , , , ) = peerReview.cases(caseId);
        require(caseType == 0, "ProposalStakeVault: not a policy proposal case");
        require(sourcePostId == postId, "ProposalStakeVault: caseId does not match postId");
        require(status == 3 || status == 4, "ProposalStakeVault: case not yet decided (must be AGENDA_ADOPTED or AGENDA_PENDING)");

        if (status == 3) {
            // AGENDA_ADOPTED: 예치금 전액 반환 + 보너스
            uint256 bonus = (s.amount * bonusBps) / 10000;
            s.status = StakeStatus.RESOLVED_REFUNDED;
            rdao.safeTransfer(s.staker, s.amount);
            // 보너스는 별도로 mint 권한을 가진 RDAOToken이어야 지급 가능하다.
            // 이 vault는 mint 권한이 없다면 아래 호출이 revert되므로, 배포 시 반드시
            // RDAOToken.setMinter(vaultAddress, true)를 실행해야 한다.
            (bool ok, ) = address(rdao).call(abi.encodeWithSignature("mint(address,uint256)", s.staker, bonus));
            require(ok, "ProposalStakeVault: bonus mint failed (vault must have MINTER_ROLE on RDAOToken)");
            emit Resolved(postId, true, s.amount, 0, bonus);
        } else {
            // AGENDA_PENDING: 일부 소각, 나머지 반환
            uint256 burnAmt = (s.amount * burnBps) / 10000;
            uint256 refundAmt = s.amount - burnAmt;
            s.status = StakeStatus.RESOLVED_BURNED;
            if (burnAmt > 0) rdaoBurnable.burn(burnAmt);
            if (refundAmt > 0) rdao.safeTransfer(s.staker, refundAmt);
            emit Resolved(postId, false, refundAmt, burnAmt, 0);
        }
    }

    // ---------------------------------------------------------------
    // 관리
    // ---------------------------------------------------------------

    function setStakeAmount(uint256 v) external onlyAdmin { stakeAmount = v; }
    function setBonusBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); bonusBps = v; }
    function setBurnBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); burnBps = v; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
