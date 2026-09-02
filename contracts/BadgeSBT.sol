// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IBadgeRenderer {
    function tokenURI(uint256 tokenId, uint8 tier, uint256 points) external view returns (string memory);
}

/**
 * @title BadgeSBT (v3 — 포인트 기반 등급제)
 * @notice 민관 협의체 DAO를 위한 양도불가(Soulbound) 평판 배지.
 *
 *         모든 신뢰 축적(동료 지지, 정책제안 게시판 활동, 거버넌스 성과인증)은
 *         하나의 누적 포인트(points)로 합산되고, 등급(tier)은 포인트 구간에 따라
 *         자동으로 산정된다. 즉 등급은 별도로 저장되는 값이 아니라 포인트로부터
 *         계산되는 파생값이다.
 *
 *         Tier 0: Observer(참관)
 *         Tier 1: Member-Bronze(정회원-동)
 *         Tier 2: Member-Silver(정회원-은)
 *         Tier 3: Member-Gold(정회원-금)
 *         Tier 4: Council(협의회)
 *         Tier 5: Elder(원로)
 *
 *         어뷰징이 확인되면 거버넌스(GOVERNANCE_ROLE)가 투표 결과에 따라
 *         포인트를 강등(슬래싱)시키거나 배지를 완전히 소각할 수 있다.
 */
contract BadgeSBT is ERC721, AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE"); // 슬래싱·성과인증 (DAOGovernance)
    bytes32 public constant POINTS_ROLE = keccak256("POINTS_ROLE");         // 포인트 가감 (ProposalBoard 등)

    uint8 public constant MAX_TIER = 5;

    struct Badge {
        bool exists;
        uint64 mintedAt;
    }

    mapping(address => Badge) public badges;
    mapping(address => uint256) public points;
    mapping(address => uint256) public tokenIdOf;
    mapping(uint256 => address) public ownerOfBadge;
    uint256 private _nextTokenId = 1;
    address public renderer;

    // tier 0..5 진입에 필요한 최소 누적 포인트
    uint256[6] public tierThresholds = [0, 100, 300, 600, 1200, 2500];

    // 동료 지지(레거시 직접 경로, 게시판과 별개로 여전히 지원): 대상당 지지자 1인 1회, 영구 기록
    mapping(address => mapping(address => bool)) public hasEndorsed;
    mapping(address => uint64) public lastEndorseAt;
    uint64 public endorseCooldown = 1 hours;
    uint256 public endorsePoints = 15; // 지지 1건당 지급 포인트

    event BadgeMinted(address indexed member, uint256 indexed tokenId);
    event Endorsed(address indexed target, address indexed endorser);
    event PointsChanged(address indexed member, int256 delta, uint256 newPoints, string reason);
    event TierChanged(address indexed member, uint8 oldTier, uint8 newTier);
    event Slashed(address indexed member, uint8 oldTier, uint8 newTier, string reason);
    event BadgeRevoked(address indexed member, string reason);

    constructor(address admin) ERC721("RegDAO Reputation Badge", "REGDAO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    // ---------------------------------------------------------------
    // 발급 (민팅)
    // ---------------------------------------------------------------

    function mint(address member) external onlyRole(REGISTRAR_ROLE) {
        require(member != address(0), "invalid address");
        require(!badges[member].exists, "RegDAO: address is already a registered member");
        _mintBadge(member, 0);
    }

    function mintAt(address member, uint8 tier) external onlyRole(REGISTRAR_ROLE) {
        require(member != address(0), "invalid address");
        require(!badges[member].exists, "RegDAO: address is already a registered member");
        require(tier <= MAX_TIER, "invalid tier");
        _mintBadge(member, tier);
    }

    function _mintBadge(address member, uint8 tier) internal {
        uint256 tokenId = _nextTokenId++;
        badges[member] = Badge({exists: true, mintedAt: uint64(block.timestamp)});
        points[member] = tierThresholds[tier];
        tokenIdOf[member] = tokenId;
        ownerOfBadge[tokenId] = member;
        _safeMint(member, tokenId);
        emit BadgeMinted(member, tokenId);
    }

    // ---------------------------------------------------------------
    // 동료 지지 (레거시 직접 경로)
    // ---------------------------------------------------------------

    function endorse(address target) external {
        require(badges[msg.sender].exists, "endorser has no badge");
        require(badges[target].exists, "target has no badge");
        require(msg.sender != target, "cannot self-endorse");
        require(tierOf(msg.sender) >= 1, "endorser must be Member+ (Bronze min)");
        require(block.timestamp >= lastEndorseAt[msg.sender] + endorseCooldown, "endorse cooldown active");
        require(!hasEndorsed[target][msg.sender], "already endorsed this member");

        hasEndorsed[target][msg.sender] = true;
        lastEndorseAt[msg.sender] = uint64(block.timestamp);
        emit Endorsed(target, msg.sender);

        _addPoints(target, int256(endorsePoints), "peer endorsement");
    }

    // ---------------------------------------------------------------
    // 포인트 가감 (거버넌스 / 정책제안 게시판 전용)
    // ---------------------------------------------------------------

    function addPoints(address member, int256 delta, string calldata reason) external onlyRole(POINTS_ROLE) {
        require(badges[member].exists, "no badge");
        _addPoints(member, delta, reason);
    }

    function levelUpByGovernance(address member, uint8 newTier, string calldata evidence)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(badges[member].exists, "no badge");
        require(newTier <= MAX_TIER, "exceeds MAX_TIER");
        uint256 floor = tierThresholds[newTier];
        require(floor > points[member], "member already at or above this tier's floor");
        _addPoints(member, int256(floor - points[member]), evidence);
    }

    function _addPoints(address member, int256 delta, string memory reason) internal {
        uint8 oldTier = tierOf(member);
        uint256 current = points[member];
        if (delta >= 0) {
            current += uint256(delta);
        } else {
            uint256 dec = uint256(-delta);
            current = current > dec ? current - dec : 0;
        }
        points[member] = current;
        emit PointsChanged(member, delta, current, reason);

        uint8 newTier = tierOf(member);
        if (newTier != oldTier) emit TierChanged(member, oldTier, newTier);
    }

    // ---------------------------------------------------------------
    // 슬래싱 (거버넌스 전용)
    // ---------------------------------------------------------------

    function slash(address member, uint8 tiersDown, string calldata reason) external onlyRole(GOVERNANCE_ROLE) {
        require(badges[member].exists, "no badge");
        uint8 oldTier = tierOf(member);

        if (tiersDown >= oldTier + 1) {
            badges[member].exists = false;
            points[member] = 0;
            uint256 tokenId = tokenIdOf[member];
            _burn(tokenId);
            emit Slashed(member, oldTier, 0, reason);
            emit BadgeRevoked(member, reason);
        } else {
            uint8 newTier = oldTier - tiersDown;
            points[member] = tierThresholds[newTier];
            emit Slashed(member, oldTier, newTier, reason);
            emit TierChanged(member, oldTier, newTier);
        }
    }

    // ---------------------------------------------------------------
    // 조회 / 투표권
    // ---------------------------------------------------------------

    function tierOf(address member) public view returns (uint8) {
        if (!badges[member].exists) return 0;
        uint256 p = points[member];
        for (uint8 i = MAX_TIER; i > 0; i--) {
            if (p >= tierThresholds[i]) return i;
        }
        return 0;
    }

    function levelOf(address member) external view returns (uint8) {
        return tierOf(member);
    }

    function pointsOf(address member) external view returns (uint256) {
        return points[member];
    }

    function pointsToNextTier(address member) external view returns (uint256) {
        uint8 t = tierOf(member);
        if (t >= MAX_TIER) return 0;
        uint256 next = tierThresholds[t + 1];
        uint256 cur = points[member];
        return next > cur ? next - cur : 0;
    }

    function tierName(uint8 tier) public pure returns (string memory) {
        if (tier == 0) return "Observer";
        if (tier == 1) return "Member-Bronze";
        if (tier == 2) return "Member-Silver";
        if (tier == 3) return "Member-Gold";
        if (tier == 4) return "Council";
        return "Elder";
    }

    function votingPowerOf(address member) external view returns (uint256) {
        if (!badges[member].exists) return 0;
        return uint256(tierOf(member)) + 1;
    }

    function isMember(address member) external view returns (bool) {
        return badges[member].exists;
    }

    // ---------------------------------------------------------------
    // 관리 함수
    // ---------------------------------------------------------------

    function setEndorseCooldown(uint64 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        endorseCooldown = seconds_;
    }

    function setEndorsePoints(uint256 pts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        endorsePoints = pts;
    }

    function setTierThreshold(uint8 tier, uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tier <= MAX_TIER, "invalid tier");
        tierThresholds[tier] = threshold;
    }

    function setRenderer(address renderer_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        renderer = renderer_;
    }

    // ---------------------------------------------------------------
    // 메타데이터 (온체인 SVG 아트워크)
    // ---------------------------------------------------------------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address owner = _ownerOf(tokenId);
        require(owner != address(0), "BadgeSBT: nonexistent token");
        if (renderer != address(0)) {
            return IBadgeRenderer(renderer).tokenURI(tokenId, tierOf(owner), points[owner]);
        }
        return super.tokenURI(tokenId);
    }

    // ---------------------------------------------------------------
    // Soulbound 강제: 전송 금지 (mint/burn만 허용)
    // ---------------------------------------------------------------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert("BadgeSBT: soulbound, non-transferable");
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
