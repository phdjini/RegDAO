// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBadgeSBTPoints {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
    function addPoints(address member, int256 delta, string calldata reason) external;
}

/**
 * @title ProposalBoard
 * @notice 디지털자산 업계의 애로사항·규제개선 제안을 자유롭게 올리고 토론하는 게시판.
 *
 *         카테고리 예시: 규제개선 제안, 업계 애로사항, 세미나 연사 초빙, 언론 기고,
 *         기타 산업 발전 기여 활동 등 — 협회 이름으로 대외 발표되는 다양한 기여를
 *         하나의 게시판에서 포괄한다.
 *
 *         어뷰징 방지의 핵심 장치(2단계 검증):
 *         1) 지지(SUPPORT)·반대(OPPOSE)를 표할 때는 반드시 근거(reason)를 남겨야 한다.
 *         2) 그 지지/반대 자체가 다른 회원들로부터 일정 수 이상의 "동의(uphold)"를
 *            받아야만 비로소 원글/댓글 작성자에게 실제 포인트로 반영된다.
 *         이렇게 하면 "묻지마 몰표"는 포인트에 영향을 주지 못하고, 설득력 있는 근거를
 *         제시한 지지/반대만 실제로 평판에 반영된다.
 */
contract ProposalBoard {
    enum Category { REGULATION, INDUSTRY_PAIN_POINT, SPEAKER_INVITATION, MEDIA_CONTRIBUTION, OTHER }
    enum TargetType { POST, COMMENT }

    struct Post {
        uint256 id;
        address author;
        Category category;
        string title;
        string content;
        string attachmentURI; // 첨부파일 (data URI 소용량 온체인 임베드 또는 외부 링크)
        uint64 createdAt;
        uint256 supportCount;   // 검증 완료된 지지 수 (표시용)
        uint256 opposeCount;    // 검증 완료된 반대 수 (표시용)
        bool exists;
    }

    struct Comment {
        uint256 id;
        uint256 postId;
        address author;
        string content;
        uint64 createdAt;
        uint256 supportCount;
        uint256 opposeCount;
        bool exists;
    }

    struct Endorsement {
        uint256 id;
        TargetType targetType;
        uint256 targetId;
        address endorser;
        bool isSupport;
        string reason;
        uint256 upholdCount;
        bool counted;
        uint64 createdAt;
        bool exists;
    }

    IBadgeSBTPoints public immutable badge;
    address public admin;

    uint256 public postCount;
    uint256 public commentCount;
    uint256 public endorsementCount;

    mapping(uint256 => Post) public posts;
    mapping(uint256 => Comment) public comments;
    mapping(uint256 => Endorsement) public endorsements;

    // 대상(targetType,targetId)당 계정 1인 1회만 지지/반대 가능
    mapping(uint8 => mapping(uint256 => mapping(address => bool))) public hasEndorsedTarget;
    // endorsement 1건당 계정 1인 1회만 uphold(동의) 가능
    mapping(uint256 => mapping(address => bool)) public hasUpheld;

    uint256 public constant MIN_REASON_LENGTH = 10;    // 근거 최소 글자 수 (바이트 기준)
    uint256 public upholdThreshold = 2;                // 포인트 반영에 필요한 동의 수
    uint256 public supportPointsAward = 10;            // 검증된 지지 1건당 원글 작성자 포인트
    uint256 public opposePointsPenalty = 5;            // 검증된 반대 1건당 원글 작성자 감점
    uint256 public upholderRewardPoints = 2;           // 근거를 잘 검증해준 동의자에게도 소액 포인트 지급
    uint8 public minPostTier = 0;                      // 제안 작성에 필요한 최소 등급.
                                                        // 테스트 단계인 현재는 0(참관 포함 전체 허용)으로 둔다.
                                                        // 정식 운영 시 등급별 글쓰기 제한을 도입할 예정이며,
                                                        // 이 값은 관리자가 언제든 상향 조정할 수 있다.
                                                        // ※ RDAO(양도 가능 토큰) 보유량은 이 판단에 전혀 관여하지
                                                        //   않는다 — 오직 소울바운드 배지의 등급(tierOf)만 본다.

    event PostCreated(uint256 indexed id, address indexed author, Category category, string title);
    event CommentCreated(uint256 indexed id, uint256 indexed postId, address indexed author);
    event EndorsementCreated(uint256 indexed id, uint8 targetType, uint256 indexed targetId, address indexed endorser, bool isSupport);
    event Upheld(uint256 indexed endorsementId, address indexed upholder, uint256 newUpholdCount);
    event EndorsementCounted(uint256 indexed endorsementId, address indexed target, bool isSupport, int256 pointsDelta);

    modifier onlyMember() {
        require(badge.isMember(msg.sender), "ProposalBoard: badge holders only");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address badgeContract, address admin_) {
        badge = IBadgeSBTPoints(badgeContract);
        admin = admin_;
    }

    // ---------------------------------------------------------------
    // 원글 / 댓글
    // ---------------------------------------------------------------

    function createPost(Category category, string calldata title, string calldata content, string calldata attachmentURI)
        external
        onlyMember
        returns (uint256)
    {
        require(badge.tierOf(msg.sender) >= minPostTier, "ProposalBoard: badge tier too low to propose");
        require(bytes(title).length > 0, "title required");
        require(bytes(content).length > 0, "content required");
        uint256 id = ++postCount;
        posts[id] = Post({
            id: id,
            author: msg.sender,
            category: category,
            title: title,
            content: content,
            attachmentURI: attachmentURI,
            createdAt: uint64(block.timestamp),
            supportCount: 0,
            opposeCount: 0,
            exists: true
        });
        emit PostCreated(id, msg.sender, category, title);
        return id;
    }

    function createComment(uint256 postId, string calldata content) external onlyMember returns (uint256) {
        require(posts[postId].exists, "ProposalBoard: post does not exist");
        require(bytes(content).length > 0, "content required");
        uint256 id = ++commentCount;
        comments[id] = Comment({
            id: id,
            postId: postId,
            author: msg.sender,
            content: content,
            createdAt: uint64(block.timestamp),
            supportCount: 0,
            opposeCount: 0,
            exists: true
        });
        emit CommentCreated(id, postId, msg.sender);
        return id;
    }

    // ---------------------------------------------------------------
    // 지지 / 반대 (근거 필수, 1단계)
    // ---------------------------------------------------------------

    function endorsePost(uint256 postId, bool isSupport, string calldata reason) external onlyMember returns (uint256) {
        require(posts[postId].exists, "ProposalBoard: post does not exist");
        require(posts[postId].author != msg.sender, "cannot endorse your own post");
        return _createEndorsement(TargetType.POST, postId, isSupport, reason);
    }

    function endorseComment(uint256 commentId, bool isSupport, string calldata reason) external onlyMember returns (uint256) {
        require(comments[commentId].exists, "ProposalBoard: comment does not exist");
        require(comments[commentId].author != msg.sender, "cannot endorse your own comment");
        return _createEndorsement(TargetType.COMMENT, commentId, isSupport, reason);
    }

    function _createEndorsement(TargetType targetType, uint256 targetId, bool isSupport, string calldata reason)
        internal
        returns (uint256)
    {
        require(bytes(reason).length >= MIN_REASON_LENGTH, "ProposalBoard: a substantive reason is required");
        uint8 tKey = uint8(targetType);
        require(!hasEndorsedTarget[tKey][targetId][msg.sender], "ProposalBoard: you already endorsed this");

        hasEndorsedTarget[tKey][targetId][msg.sender] = true;

        uint256 id = ++endorsementCount;
        endorsements[id] = Endorsement({
            id: id,
            targetType: targetType,
            targetId: targetId,
            endorser: msg.sender,
            isSupport: isSupport,
            reason: reason,
            upholdCount: 0,
            counted: false,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        emit EndorsementCreated(id, tKey, targetId, msg.sender, isSupport);
        return id;
    }

    // ---------------------------------------------------------------
    // 근거에 대한 동의 (2단계 검증)
    // ---------------------------------------------------------------

    /// @notice 지지/반대의 "근거"에 대해 다른 회원이 동의를 표한다. 동의 수가 임계값에
    ///         도달하는 순간, 그 지지/반대가 비로소 실제 포인트로 반영된다.
    function uphold(uint256 endorsementId) external onlyMember {
        Endorsement storage e = endorsements[endorsementId];
        require(e.exists, "ProposalBoard: endorsement does not exist");
        require(e.endorser != msg.sender, "cannot uphold your own endorsement");
        require(!hasUpheld[endorsementId][msg.sender], "ProposalBoard: you already upheld this");

        address targetAuthor = _authorOf(e.targetType, e.targetId);
        require(targetAuthor != msg.sender, "target author cannot uphold endorsements on their own content");

        hasUpheld[endorsementId][msg.sender] = true;
        e.upholdCount += 1;
        emit Upheld(endorsementId, msg.sender, e.upholdCount);

        // 검증에 참여한 동의자에게도 소액의 포인트를 지급해 성실한 검토를 유도
        if (upholderRewardPoints > 0) {
            badge.addPoints(msg.sender, int256(upholderRewardPoints), "verified another member's reasoning");
        }

        if (!e.counted && e.upholdCount >= upholdThreshold) {
            e.counted = true;
            _applyEndorsementEffect(e, targetAuthor);
        }
    }

    function _applyEndorsementEffect(Endorsement storage e, address targetAuthor) internal {
        if (e.isSupport) {
            if (e.targetType == TargetType.POST) posts[e.targetId].supportCount += 1;
            else comments[e.targetId].supportCount += 1;

            badge.addPoints(targetAuthor, int256(supportPointsAward), e.reason);
            emit EndorsementCounted(e.id, targetAuthor, true, int256(supportPointsAward));
        } else {
            if (e.targetType == TargetType.POST) posts[e.targetId].opposeCount += 1;
            else comments[e.targetId].opposeCount += 1;

            badge.addPoints(targetAuthor, -int256(opposePointsPenalty), e.reason);
            emit EndorsementCounted(e.id, targetAuthor, false, -int256(opposePointsPenalty));
        }
    }

    function _authorOf(TargetType targetType, uint256 targetId) internal view returns (address) {
        if (targetType == TargetType.POST) return posts[targetId].author;
        return comments[targetId].author;
    }

    // ---------------------------------------------------------------
    // 관리
    // ---------------------------------------------------------------

    function setUpholdThreshold(uint256 v) external onlyAdmin { upholdThreshold = v; }
    function setSupportPointsAward(uint256 v) external onlyAdmin { supportPointsAward = v; }
    function setOpposePointsPenalty(uint256 v) external onlyAdmin { opposePointsPenalty = v; }
    function setUpholderRewardPoints(uint256 v) external onlyAdmin { upholderRewardPoints = v; }
    function setMinPostTier(uint8 tier) external onlyAdmin { minPostTier = tier; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
