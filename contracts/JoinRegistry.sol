// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBadgeSBTMembership {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
}

/**
 * @title JoinRegistry
 * @notice 신규 회원 가입 신청을 온체인에 기록하는 레지스트리.
 *         실제 배지 발급(mint)은 여전히 BadgeSBT의 REGISTRAR_ROLE 보유자가 수행한다.
 *
 *         각 신청에는 창립 등급(Council/Elder, 기본 Tier 4 이상) 회원 중에서 무작위로
 *         선정된 "심사 담당자(assignedReviewer)"가 배정된다. 무작위 선정 자체는
 *         온체인 난수의 조작 가능성을 피하기 위해 오프체인 AI 에이전트(AGENT_ROLE)가
 *         수행하고, 이 컨트랙트는 그 배정 결과만 기록한다. 승인/반려는 관리자 또는
 *         배정된 심사 담당자만 수행할 수 있다.
 *
 *         예외 처리: 이미 배지를 보유한 주소, 이미 승인된 신청 이력이 있는 주소,
 *         대기 중인 신청이 있는 주소는 각각 명확한 사유와 함께 즉시 거부된다.
 */
contract JoinRegistry {
    struct Application {
        address applicant;
        string reason;      // 가입 사유/소개 (성명·연락처 포함하여 구성됨)
        string org;         // 소속(민간 기관명 또는 관 부서명 등)
        uint64 submittedAt;
        address assignedReviewer; // 무작위 배정된 심사 담당자 (미배정 시 address(0))
        uint64 assignedAt;
        bool approved;
        bool rejected;
    }

    IBadgeSBTMembership public immutable badge;
    address public admin;
    uint8 public minApproverTier = 4; // 창립 등급 기준 (기본: Council 이상)

    uint256 public applicationCount;
    mapping(uint256 => Application) public applications;
    mapping(address => uint256) public latestApplicationOf; // 0이면 신청 이력 없음
    mapping(address => bool) public hasPendingApplication;
    mapping(address => bool) public hasEverBeenApproved; // 승인 이력이 있으면 재신청 자체를 막음
    mapping(address => bool) public hasAgentRole;

    event Applied(uint256 indexed id, address indexed applicant, string org, string reason);
    event ReviewerAssigned(uint256 indexed id, address indexed reviewer);
    event Approved(uint256 indexed id, address indexed applicant, address indexed reviewer);
    event Rejected(uint256 indexed id, address indexed applicant, address indexed reviewer, string reason);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyAgent() {
        require(hasAgentRole[msg.sender], "JoinRegistry: agent only");
        _;
    }

    modifier onlyAdminOrAssignedReviewer(uint256 id) {
        Application storage a = applications[id];
        require(
            msg.sender == admin || (a.assignedReviewer != address(0) && msg.sender == a.assignedReviewer),
            "JoinRegistry: only admin or the assigned reviewer can act on this application"
        );
        _;
    }

    constructor(address badgeContract, address admin_) {
        badge = IBadgeSBTMembership(badgeContract);
        admin = admin_;
        hasAgentRole[admin_] = true; // 초기에는 admin이 에이전트 역할 겸임 (수동 운영 가능)
    }

    function submitApplication(string calldata org, string calldata reason) external returns (uint256) {
        require(!badge.isMember(msg.sender), "JoinRegistry: this address is already a registered member");
        require(!hasEverBeenApproved[msg.sender], "JoinRegistry: this address has already been approved before");
        require(!hasPendingApplication[msg.sender], "JoinRegistry: you already have a pending application");
        require(bytes(org).length > 0, "organization is required");
        require(bytes(reason).length > 0, "reason is required");

        uint256 id = ++applicationCount;
        applications[id] = Application({
            applicant: msg.sender,
            reason: reason,
            org: org,
            submittedAt: uint64(block.timestamp),
            assignedReviewer: address(0),
            assignedAt: 0,
            approved: false,
            rejected: false
        });
        latestApplicationOf[msg.sender] = id;
        hasPendingApplication[msg.sender] = true;
        emit Applied(id, msg.sender, org, reason);
        return id;
    }

    /// @notice 오프체인 에이전트가 창립 등급 이상 회원 중 무작위로 고른 심사 담당자를 기록한다.
    function assignReviewer(uint256 id, address reviewer) external onlyAgent {
        Application storage a = applications[id];
        require(a.applicant != address(0), "no such application");
        require(!a.approved && !a.rejected, "JoinRegistry: application already resolved");
        require(badge.isMember(reviewer) && badge.tierOf(reviewer) >= minApproverTier, "JoinRegistry: reviewer must meet minimum founder tier");

        a.assignedReviewer = reviewer;
        a.assignedAt = uint64(block.timestamp);
        emit ReviewerAssigned(id, reviewer);
    }

    /// @notice 실제 배지 발급은 BadgeSBT.mint()로 별도 수행한 뒤, 이 함수로 신청 상태만 정리한다.
    function markApproved(uint256 id) external onlyAdminOrAssignedReviewer(id) {
        Application storage a = applications[id];
        require(a.applicant != address(0), "no such application");
        require(!a.approved, "JoinRegistry: this application was already approved");
        require(!a.rejected, "JoinRegistry: this application was already rejected");
        a.approved = true;
        hasPendingApplication[a.applicant] = false;
        hasEverBeenApproved[a.applicant] = true;
        emit Approved(id, a.applicant, msg.sender);
    }

    function reject(uint256 id, string calldata reason) external onlyAdminOrAssignedReviewer(id) {
        Application storage a = applications[id];
        require(a.applicant != address(0), "no such application");
        require(!a.approved, "JoinRegistry: cannot reject an already-approved application");
        require(!a.rejected, "JoinRegistry: this application was already rejected");
        a.rejected = true;
        hasPendingApplication[a.applicant] = false;
        emit Rejected(id, a.applicant, msg.sender, reason);
    }

    // ---------------------------------------------------------------
    // 관리
    // ---------------------------------------------------------------

    function setAgent(address agent, bool enabled) external onlyAdmin {
        hasAgentRole[agent] = enabled;
    }

    function setMinApproverTier(uint8 tier) external onlyAdmin {
        minApproverTier = tier;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }
}
