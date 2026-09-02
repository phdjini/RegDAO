// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BadgeSBT.sol";
import "./Charter.sol";

/**
 * @title DAOGovernance
 * @notice 배지(BadgeSBT) 레벨을 투표권으로 사용하는 민관 협의체 DAO 거버넌스.
 *         일반 안건(GENERAL), 슬래싱 안건(SLASH), 정관 개정(CHARTER_AMENDMENT),
 *         성과 인증 레벨업(ACHIEVEMENT) 제안을 지원한다.
 *         정족수·투표기간은 Charter 컨트랙트에서 읽어오며, 정관 개정은 더 엄격한
 *         가중 정족수(quorumAmendment)를 요구한다.
 */
contract DAOGovernance is ReentrancyGuard {
    enum ProposalType { GENERAL, SLASH, CHARTER_AMENDMENT, ACHIEVEMENT }
    enum VoteChoice { NONE, FOR, AGAINST, ABSTAIN }
    enum ProposalState { PENDING, ACTIVE, DEFEATED, SUCCEEDED, EXECUTED, CANCELED }

    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType pType;
        string description;
        // GENERAL / CHARTER_AMENDMENT 안건 실행용
        address target;
        uint256 value;
        bytes data;
        // SLASH 안건 파라미터
        address slashTarget;
        uint8 slashLevels;
        // ACHIEVEMENT 안건 파라미터
        address achievementTarget;
        uint8 achievementLevel;
        // 투표 집계 (생성 시점의 Charter 파라미터를 스냅샷으로 고정)
        uint256 startTime;
        uint256 endTime;
        uint256 requiredQuorum;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool canceled;
    }

    BadgeSBT public immutable badge;
    Charter public immutable charter;
    address public admin;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => VoteChoice)) public votesCast;

    uint8 public constant MIN_PROPOSAL_LEVEL = 1;   // Member-Bronze 이상만 제안 가능 (Tier 1+)
    uint8 public constant MIN_AMENDMENT_PROPOSAL_LEVEL = 4; // 정관 개정은 Council 이상만 제안 가능 (Tier 4+)

    event ProposalCreated(uint256 indexed id, address indexed proposer, ProposalType pType, string description);
    event VoteCast(uint256 indexed id, address indexed voter, VoteChoice choice, uint256 power);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address badgeContract, address charterContract, address admin_) {
        badge = BadgeSBT(badgeContract);
        charter = Charter(charterContract);
        admin = admin_;
    }

    // ---------------------------------------------------------------
    // 제안 생성
    // ---------------------------------------------------------------

    function proposeGeneral(string calldata description, address target, uint256 value, bytes calldata data)
        external
        returns (uint256)
    {
        require(badge.levelOf(msg.sender) >= MIN_PROPOSAL_LEVEL, "insufficient badge level to propose");
        uint256 id = _newProposal(ProposalType.GENERAL, description, charter.quorumNormal(), charter.votingPeriodNormal());
        Proposal storage p = proposals[id];
        p.target = target;
        p.value = value;
        p.data = data;
        emit ProposalCreated(id, msg.sender, ProposalType.GENERAL, description);
        return id;
    }

    /// @notice 어뷰징 신고에 따른 슬래싱 안건 발의.
    function proposeSlash(string calldata reason, address slashTarget, uint8 slashLevels) external returns (uint256) {
        require(badge.levelOf(msg.sender) >= MIN_PROPOSAL_LEVEL, "insufficient badge level to propose");
        require(badge.isMember(slashTarget), "target has no badge");
        require(slashLevels > 0, "slashLevels must be > 0");
        uint256 id = _newProposal(ProposalType.SLASH, reason, charter.quorumNormal(), charter.votingPeriodNormal());
        Proposal storage p = proposals[id];
        p.slashTarget = slashTarget;
        p.slashLevels = slashLevels;
        emit ProposalCreated(id, msg.sender, ProposalType.SLASH, reason);
        return id;
    }

    /// @notice 정관 개정 제안. target은 반드시 Charter 컨트랙트 주소여야 하며,
    ///         data는 Charter의 개정 함수(setQuorumNormal 등) 호출 인코딩이다.
    ///         일반 안건보다 더 엄격한 가중 정족수(quorumAmendment)가 적용된다.
    function proposeCharterAmendment(string calldata description, bytes calldata data) external returns (uint256) {
        require(badge.levelOf(msg.sender) >= MIN_AMENDMENT_PROPOSAL_LEVEL, "insufficient badge level (Council+ required)");
        uint256 id = _newProposal(
            ProposalType.CHARTER_AMENDMENT,
            description,
            charter.quorumAmendment(),
            charter.votingPeriodAmendment()
        );
        Proposal storage p = proposals[id];
        p.target = address(charter);
        p.data = data;
        emit ProposalCreated(id, msg.sender, ProposalType.CHARTER_AMENDMENT, description);
        return id;
    }

    /// @notice 정성적 기여(해외 연사 초빙, 기고문 발표, 게시판 제안 지지 획득 등)에 대한
    ///         성과 인증 레벨업 제안. evidence는 description에 근거/링크를 포함해 작성한다.
    function proposeAchievement(string calldata description, address member, uint8 newLevel) external returns (uint256) {
        require(badge.levelOf(msg.sender) >= MIN_PROPOSAL_LEVEL, "insufficient badge level to propose");
        require(badge.isMember(member), "target has no badge");
        uint256 id = _newProposal(ProposalType.ACHIEVEMENT, description, charter.quorumNormal(), charter.votingPeriodNormal());
        Proposal storage p = proposals[id];
        p.achievementTarget = member;
        p.achievementLevel = newLevel;
        emit ProposalCreated(id, msg.sender, ProposalType.ACHIEVEMENT, description);
        return id;
    }

    function _newProposal(ProposalType pType, string calldata description, uint256 quorum, uint256 period)
        internal
        returns (uint256)
    {
        uint256 id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.id = id;
        p.proposer = msg.sender;
        p.pType = pType;
        p.description = description;
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + period;
        p.requiredQuorum = quorum;
        return id;
    }

    // ---------------------------------------------------------------
    // 투표
    // ---------------------------------------------------------------

    function castVote(uint256 id, VoteChoice choice) external {
        Proposal storage p = proposals[id];
        require(p.id != 0, "no such proposal");
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "voting closed");
        require(votesCast[id][msg.sender] == VoteChoice.NONE, "already voted");
        require(choice != VoteChoice.NONE, "invalid choice");

        uint256 power = badge.votingPowerOf(msg.sender);
        require(power > 0, "no voting power (no badge)");

        votesCast[id][msg.sender] = choice;

        if (choice == VoteChoice.FOR) p.forVotes += power;
        else if (choice == VoteChoice.AGAINST) p.againstVotes += power;
        else p.abstainVotes += power;

        emit VoteCast(id, msg.sender, choice, power);
    }

    // ---------------------------------------------------------------
    // 상태 조회
    // ---------------------------------------------------------------

    function state(uint256 id) public view returns (ProposalState) {
        Proposal storage p = proposals[id];
        require(p.id != 0, "no such proposal");
        if (p.canceled) return ProposalState.CANCELED;
        if (p.executed) return ProposalState.EXECUTED;
        if (block.timestamp <= p.endTime) return ProposalState.ACTIVE;

        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        if (totalVotes < p.requiredQuorum) return ProposalState.DEFEATED;
        if (p.forVotes > p.againstVotes) return ProposalState.SUCCEEDED;
        return ProposalState.DEFEATED;
    }

    // ---------------------------------------------------------------
    // 실행
    // ---------------------------------------------------------------

    function execute(uint256 id) external nonReentrant {
        require(state(id) == ProposalState.SUCCEEDED, "proposal not succeeded");
        Proposal storage p = proposals[id];
        p.executed = true;

        if (p.pType == ProposalType.SLASH) {
            badge.slash(p.slashTarget, p.slashLevels, p.description);
        } else if (p.pType == ProposalType.ACHIEVEMENT) {
            badge.levelUpByGovernance(p.achievementTarget, p.achievementLevel, p.description);
        } else if (p.pType == ProposalType.CHARTER_AMENDMENT) {
            require(p.target == address(charter), "charter amendment must target Charter");
            (bool ok, ) = p.target.call(p.data);
            require(ok, "charter amendment execution failed");
        } else {
            (bool ok, ) = p.target.call{value: p.value}(p.data);
            require(ok, "execution failed");
        }
        emit ProposalExecuted(id);
    }

    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        require(msg.sender == p.proposer || msg.sender == admin, "not authorized");
        require(!p.executed, "already executed");
        p.canceled = true;
        emit ProposalCanceled(id);
    }

    receive() external payable {}
}
