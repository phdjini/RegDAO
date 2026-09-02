// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBadgeSBTMember {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
}

/**
 * @title MemberProfile
 * @notice 회원의 관심분야·전문성·연락처를 온체인에 기록한다.
 *         오프체인 AI 에이전트(피어리뷰 매칭, 가입승인 배정 서비스)가 이 정보를 읽어
 *         제안 내용과 가장 유사한 에디터·리뷰어, 혹은 무작위 배정 대상을 선정하는 데 사용한다.
 *
 *         이메일과 휴대폰 번호는 배정 통지(메일·문자) 수신을 위해 필수로 입력해야 한다.
 */
contract MemberProfile {
    IBadgeSBTMember public immutable badge;

    struct Profile {
        string bio;
        string[] interests; // 예: ["규제", "스테이블코인", "과세", "커스터디"]
        string email;       // 필수 - 위촉/배정 메일 수신용
        string phone;        // 필수 - 위촉/배정 문자 수신용 (E.164 권장, 예: +821012345678)
        bool exists;
    }

    mapping(address => Profile) private profiles;
    address[] public profiledMembers; // 프로필을 설정한 회원 목록 (에이전트 후보군 스캔용)
    mapping(address => bool) private _isInList;

    event ProfileUpdated(address indexed member);

    modifier onlyMember() {
        require(badge.isMember(msg.sender), "MemberProfile: badge holders only");
        _;
    }

    constructor(address badgeContract) {
        badge = IBadgeSBTMember(badgeContract);
    }

    function setProfile(
        string calldata bio,
        string[] calldata interests,
        string calldata email,
        string calldata phone
    ) external onlyMember {
        require(bytes(email).length > 0, "MemberProfile: email is required");
        require(bytes(phone).length > 0, "MemberProfile: phone number is required");

        Profile storage p = profiles[msg.sender];
        p.bio = bio;
        p.email = email;
        p.phone = phone;
        delete p.interests;
        for (uint256 i = 0; i < interests.length; i++) {
            p.interests.push(interests[i]);
        }
        p.exists = true;

        if (!_isInList[msg.sender]) {
            _isInList[msg.sender] = true;
            profiledMembers.push(msg.sender);
        }
        emit ProfileUpdated(msg.sender);
    }

    function getProfile(address member)
        external
        view
        returns (string memory bio, string[] memory interests, string memory email, string memory phone, bool exists)
    {
        Profile storage p = profiles[member];
        return (p.bio, p.interests, p.email, p.phone, p.exists);
    }

    function profiledMemberCount() external view returns (uint256) {
        return profiledMembers.length;
    }

    /// @notice 창립 등급(Council/Elder, Tier 4 이상) 이상이면서 프로필을 등록한 회원 수.
    ///         가입 승인자 무작위 배정 후보군 규모를 대시보드에서 확인하는 용도.
    function eligibleApproverCount(uint8 minTier) external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < profiledMembers.length; i++) {
            address m = profiledMembers[i];
            if (badge.isMember(m) && badge.tierOf(m) >= minTier) count++;
        }
        return count;
    }
}
