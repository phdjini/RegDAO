// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Charter
 * @notice 협의체의 unicode"정관"을 온체인에 명문화한 컨트랙트.
 *         - 일반 안건/슬래싱/성과인증 제안의 정족수·투표기간
 *         - 정관 개정 자체에 필요한 더 엄격한(가중) 정족수·투표기간
 *         - 창립 요건, 신규 가입 요건, 슬래싱(제재) 사유, 레벨업 경로(정성적 기여 포함)
 *         텍스트를 온체인 이벤트로 기록하여 개정 이력을 투명하게 남긴다.
 *
 *         파라미터 변경은 오직 DAOGovernance(거버넌스 투표를 통과한 CHARTER_AMENDMENT
 *         제안)만 호출할 수 있다. 즉, 정관 개정도 반드시 정족수를 충족하는 투표를 거쳐야 한다.
 */
contract Charter {
    address public admin;       // 초기 설정 전용 (governance 주소 지정까지만 사용)
    address public governance;  // DAOGovernance 컨트랙트 주소 (설정 후에는 이곳만 개정 가능)

    // --- 정족수 / 투표기간 파라미터 ---
    uint256 public quorumNormal = 5;        // 일반 안건·슬래싱·성과인증 제안 정족수
    uint256 public quorumAmendment = 12;    // 정관 개정 제안 정족수 (가중치 적용, 더 엄격)
    uint256 public votingPeriodNormal = 3 days;
    uint256 public votingPeriodAmendment = 7 days; // 정관 개정은 숙고 기간을 더 길게

    // --- 정성적 조건 텍스트(정관 조항) ---
    string public foundingCharterText =
        unicode"창립총회에서 민간 대표단과 관 대표단이 합의하여 지정한 인사를 창립 회원(Lv2~3)으로 부트스트랩한다.";

    string[] public membershipCriteria;   // 신규 가입 요건 조항들
    string[] public slashingCriteria;     // 슬래싱(제재) 사유 조항들
    mapping(uint8 => string[]) public levelUpCriteria; // 레벨별 정성적 레벨업 경로 조항들

    // --- 개정 이력 ---
    struct Amendment {
        uint256 proposalId;
        string field;
        string oldValue;
        string newValue;
        uint64 timestamp;
    }
    Amendment[] public amendmentHistory;

    event GovernanceSet(address indexed governance);
    event ParameterChanged(string field, string oldValue, string newValue, uint256 proposalId);
    event CriterionAdded(string category, uint8 level, string text);
    event CriterionRemoved(string category, uint8 level, uint256 index);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyGovernance() {
        if (governance == address(0)) {
            // 부트스트랩 단계: DAOGovernance가 아직 연결되지 않았다면 admin이 초기값을 설정할 수 있다.
            require(msg.sender == admin, "bootstrap phase: admin only");
        } else {
            require(msg.sender == governance, "only governance (charter amendment vote) can call this");
        }
        _;
    }

    constructor(address admin_) {
        admin = admin_;

        // 초기 정관 조항 (배포 후 거버넌스 투표로 자유롭게 개정 가능)
        membershipCriteria.push(unicode"등록기관(REGISTRAR)의 심사를 통과한 개인 또는 기관.");
        membershipCriteria.push(unicode"협의체의 목적(산업 발전 및 규제 개선)에 부합하는 활동 의지가 있는 자.");

        slashingCriteria.push(unicode"허위 계정(sybil)을 이용한 지지(endorse) 조작.");
        slashingCriteria.push(unicode"협의체의 명의를 도용하거나 명예를 훼손하는 행위.");
        slashingCriteria.push(unicode"정당한 사유 없는 거버넌스 절차 방해 또는 반복적 어뷰징.");

        levelUpCriteria[2].push(unicode"정회원 지지(endorse) 3명 이상 확보 시 자동 승급.");
        levelUpCriteria[2].push(unicode"[정성 요건] 협회 게시판에 규제 개선/개혁 제안을 올려 정회원 이상으로부터 일정 수 이상 지지를 받은 경우, 거버넌스 성과인증 제안을 통해 승급 가능.");
        levelUpCriteria[3].push(unicode"협의회 지지(endorse) 5명 이상 확보 시 자동 승급.");
        levelUpCriteria[3].push(unicode"[정성 요건] 협회 정기세미나에 해외 유력 인사를 발표자로 초빙하여 성사시킨 경우, 거버넌스 성과인증 제안을 통해 승급 가능.");
        levelUpCriteria[4].push(unicode"원로 지지(endorse) 8명 이상 확보 시 자동 승급.");
        levelUpCriteria[4].push(unicode"[정성 요건] 산업 발전에 기여하는 기고문·발표를 협회 명의로 대외 공표한 경우, 거버넌스 성과인증 제안을 통해 승급 가능.");
    }

    /// @notice DAOGovernance 배포 후 1회 연결. 이후 파라미터 변경 권한은 governance로 완전히 이전된다.
    function setGovernance(address governance_) external onlyAdmin {
        require(governance == address(0), "governance already set");
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    // ---------------------------------------------------------------
    // 정족수 / 투표기간 개정 (governance = 정관개정 제안 통과 시에만 호출됨)
    // ---------------------------------------------------------------

    function setQuorumNormal(uint256 newValue, uint256 proposalId) external onlyGovernance {
        _logChange("quorumNormal", _u(quorumNormal), _u(newValue), proposalId);
        quorumNormal = newValue;
    }

    function setQuorumAmendment(uint256 newValue, uint256 proposalId) external onlyGovernance {
        _logChange("quorumAmendment", _u(quorumAmendment), _u(newValue), proposalId);
        quorumAmendment = newValue;
    }

    function setVotingPeriodNormal(uint256 newValueSeconds, uint256 proposalId) external onlyGovernance {
        _logChange("votingPeriodNormal", _u(votingPeriodNormal), _u(newValueSeconds), proposalId);
        votingPeriodNormal = newValueSeconds;
    }

    function setVotingPeriodAmendment(uint256 newValueSeconds, uint256 proposalId) external onlyGovernance {
        _logChange("votingPeriodAmendment", _u(votingPeriodAmendment), _u(newValueSeconds), proposalId);
        votingPeriodAmendment = newValueSeconds;
    }

    function setFoundingCharterText(string calldata newText, uint256 proposalId) external onlyGovernance {
        _logChange("foundingCharterText", foundingCharterText, newText, proposalId);
        foundingCharterText = newText;
    }

    // ---------------------------------------------------------------
    // 조항 추가/삭제 (가입 요건 / 슬래싱 사유 / 레벨업 경로)
    // ---------------------------------------------------------------

    function addMembershipCriterion(string calldata text) external onlyGovernance {
        membershipCriteria.push(text);
        emit CriterionAdded("membership", 0, text);
    }

    function removeMembershipCriterion(uint256 index) external onlyGovernance {
        _removeAt(membershipCriteria, index);
        emit CriterionRemoved("membership", 0, index);
    }

    function addSlashingCriterion(string calldata text) external onlyGovernance {
        slashingCriteria.push(text);
        emit CriterionAdded("slashing", 0, text);
    }

    function removeSlashingCriterion(uint256 index) external onlyGovernance {
        _removeAt(slashingCriteria, index);
        emit CriterionRemoved("slashing", 0, index);
    }

    function addLevelUpCriterion(uint8 level, string calldata text) external onlyGovernance {
        levelUpCriteria[level].push(text);
        emit CriterionAdded("levelup", level, text);
    }

    function removeLevelUpCriterion(uint8 level, uint256 index) external onlyGovernance {
        _removeAt(levelUpCriteria[level], index);
        emit CriterionRemoved("levelup", level, index);
    }

    // ---------------------------------------------------------------
    // 조회 헬퍼 (배열 전체 반환 - 대시보드용)
    // ---------------------------------------------------------------

    function getMembershipCriteria() external view returns (string[] memory) {
        return membershipCriteria;
    }

    function getSlashingCriteria() external view returns (string[] memory) {
        return slashingCriteria;
    }

    function getLevelUpCriteria(uint8 level) external view returns (string[] memory) {
        return levelUpCriteria[level];
    }

    function amendmentHistoryLength() external view returns (uint256) {
        return amendmentHistory.length;
    }

    // ---------------------------------------------------------------
    // 내부 유틸
    // ---------------------------------------------------------------

    function _removeAt(string[] storage arr, uint256 index) internal {
        require(index < arr.length, "index out of range");
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }

    function _logChange(string memory field, string memory oldV, string memory newV, uint256 proposalId) internal {
        amendmentHistory.push(Amendment(proposalId, field, oldV, newV, uint64(block.timestamp)));
        emit ParameterChanged(field, oldV, newV, proposalId);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return _toString(v);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
