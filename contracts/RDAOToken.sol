// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RDAOToken
 * @notice RegDAO 협회 활동에 대한 내부 보상·결제용 유틸리티 토큰이다.
 *
 *         ⚠️ 중요: 이 토큰은 원화(KRW)나 그 어떤 법정통화와도 1:1 교환이 보장되지 않는
 *         "협회 내부 포인트/유틸리티 토큰"이다. 실제 원화 담보가 예치되어 있지 않으며,
 *         전자금융거래법상 선불전자지급수단이나 전자화폐가 아니다. 협회 회비 납부,
 *         행사 참가비 결제, 제안 예치금(스테이킹) 등 협회 내부 활동에서만 사용된다.
 *
 *         지급 경로:
 *         - 동료검토(피어리뷰)에서 정책제안서가 발행될 때 참여한 에디터·리뷰어에게 보상 지급
 *         - 제안마당/정관개정 제안이 통과되었을 때 예치금 반환과 함께 보너스 지급
 */
contract RDAOToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    string public constant DISCLAIMER =
        "RDAO is an internal utility token for RegDAO association activities only. "
        "It is NOT a stablecoin and carries no guarantee of exchange for KRW or any fiat currency.";

    constructor(address admin) ERC20("RegDAO Reward Token", "RDAO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function setMinter(address minter, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _grantRole(MINTER_ROLE, minter);
        else _revokeRole(MINTER_ROLE, minter);
    }
}
