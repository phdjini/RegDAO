// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBadgeSBTMembershipCheck {
    function isMember(address member) external view returns (bool);
}

/**
 * @title MembershipFeeVault
 * @notice RDAO 토큰으로 연회비를 납부하거나, 세미나·행사 참가비를 결제하는 컨트랙트.
 *         납부된 RDAO는 협회 운영 계정(treasury)으로 귀속된다.
 */
contract MembershipFeeVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable rdao;
    IBadgeSBTMembershipCheck public immutable badge;
    address public admin;
    address public treasury;

    uint256 public annualFeeAmount;             // 연회비 (RDAO, wei 단위)
    uint256 public constant FEE_PERIOD = 365 days;
    mapping(address => uint256) public feePaidUntil; // 회비 납부 만료 시각

    struct Event {
        string name;
        uint256 feeAmount;
        bool active;
    }
    uint256 public eventCount;
    mapping(uint256 => Event) public events;
    mapping(uint256 => mapping(address => bool)) public eventPaid;

    event FeePaid(address indexed member, uint256 amount, uint256 paidUntil);
    event EventCreated(uint256 indexed eventId, string name, uint256 feeAmount);
    event EventFeePaid(uint256 indexed eventId, address indexed member, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address rdaoToken, address badgeContract, address admin_, address treasury_) {
        rdao = IERC20(rdaoToken);
        badge = IBadgeSBTMembershipCheck(badgeContract);
        admin = admin_;
        treasury = treasury_;
        annualFeeAmount = 50 * 1e18; // 기본값 50 RDAO, 관리자가 조정 가능
    }

    /// @notice 연회비를 RDAO로 납부한다. 이미 유효기간이 남아있으면 그만큼 이어서 연장된다.
    function payAnnualFee() external {
        require(badge.isMember(msg.sender), "MembershipFeeVault: badge holders only");
        require(annualFeeAmount > 0, "fee not configured");

        rdao.safeTransferFrom(msg.sender, treasury, annualFeeAmount);

        uint256 base = feePaidUntil[msg.sender] > block.timestamp ? feePaidUntil[msg.sender] : block.timestamp;
        feePaidUntil[msg.sender] = base + FEE_PERIOD;
        emit FeePaid(msg.sender, annualFeeAmount, feePaidUntil[msg.sender]);
    }

    function isFeeCurrent(address member) external view returns (bool) {
        return feePaidUntil[member] >= block.timestamp;
    }

    // ---------------------------------------------------------------
    // 행사(세미나 등) 참가비
    // ---------------------------------------------------------------

    function createEvent(string calldata name, uint256 feeAmount) external onlyAdmin returns (uint256) {
        uint256 id = ++eventCount;
        events[id] = Event({ name: name, feeAmount: feeAmount, active: true });
        emit EventCreated(id, name, feeAmount);
        return id;
    }

    function payEventFee(uint256 eventId) external {
        Event storage e = events[eventId];
        require(e.active, "MembershipFeeVault: event not active");
        require(badge.isMember(msg.sender), "MembershipFeeVault: badge holders only");
        require(!eventPaid[eventId][msg.sender], "MembershipFeeVault: already paid for this event");

        eventPaid[eventId][msg.sender] = true;
        rdao.safeTransferFrom(msg.sender, treasury, e.feeAmount);
        emit EventFeePaid(eventId, msg.sender, e.feeAmount);
    }

    function setEventActive(uint256 eventId, bool active) external onlyAdmin {
        events[eventId].active = active;
    }

    // ---------------------------------------------------------------
    // 관리
    // ---------------------------------------------------------------

    function setAnnualFeeAmount(uint256 amount) external onlyAdmin { annualFeeAmount = amount; }
    function setTreasury(address t) external onlyAdmin { treasury = t; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
