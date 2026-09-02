// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBadgeSBTPoints2 {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
    function addPoints(address member, int256 delta, string calldata reason) external;
}

interface IRDAOMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @title PeerReview
 * @notice 정책제안 게시판의 안건 또는 정성적 성과 주장을, 논문 피어리뷰와 유사한 절차로
 *         심사하고 최종 정책제안서를 발행하는 프로세스를 온체인에 기록한다.
 *
 *         절차: 케이스 개시(지지수 임계값 충족 또는 성과 주장 제출)
 *              -> 주에디터·보조에디터 배정
 *              -> 리뷰어 모집(초대 -> 수락/거절, 최소 3명 수락 시 리뷰 개시)
 *              -> (비공개 질의응답은 이메일로 오프체인 진행 — 이 컨트랙트는 상태 전이만 기록)
 *              -> 리뷰 제출 -> 에디터가 최종 정책제안서 발행 (투표 불필요, 즉시 발행)
 *
 *         에디터/리뷰어 배정과 초대·응답 기록은 AI 에이전트(AGENT_ROLE, Claude API로 판단하는
 *         오프체인 Node 서비스의 지갑)가 호출한다. 이 컨트랙트 자체는 AI 판단을 수행하지 않고,
 *         그 판단의 결과(누가 배정되었는지, 언제 수락했는지, 최종 문서가 무엇인지)만 투명하게
 *         기록하여 추후 검증 가능하게 한다.
 */
contract PeerReview {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    enum CaseType { POLICY_PROPOSAL, ACHIEVEMENT }
    enum CaseStatus { EDITOR_PENDING, RECRUITING_REVIEWERS, IN_REVIEW, AGENDA_ADOPTED, AGENDA_PENDING, PUBLISHED, CANCELED }
    enum InviteStatus { INVITED, ACCEPTED, DECLINED, TIMED_OUT }

    struct ReviewCase {
        uint256 id;
        CaseType caseType;
        uint256 sourcePostId;   // POLICY_PROPOSAL인 경우 ProposalBoard의 postId, ACHIEVEMENT면 0
        address claimant;       // 성과 주장자 또는 원 제안 작성자
        string description;     // 성과 주장 설명 (ACHIEVEMENT), POLICY_PROPOSAL은 게시판 원글 참조
        address chiefEditor;
        address coEditor;
        CaseStatus status;
        uint64 createdAt;
        uint64 publishedAt;
        uint256 approveCount;    // 리뷰어 중 "찬성(Approve)" 판정 수
        bool adopted;            // 2/3 이상 찬성 시 true (의안상정)
        string finalTitle;
        string finalDocumentURI; // 최종 정책제안서 원문(IPFS 등) 링크
        string finalSummary;
    }

    struct ReviewerInvite {
        address reviewer;
        InviteStatus status;
        uint64 invitedAt;
        uint64 respondedAt;
        bool reviewSubmitted;
        bool approve;      // 리뷰 판정: true=찬성(Approve), false=반대
        string reviewURI; // 리뷰 의견 원문 링크 (필요 시 비공개 저장소, 온체인엔 포인터만)
    }

    IBadgeSBTPoints2 public immutable badge;
    address public admin;
    IRDAOMintable public rdaoToken;             // 설정 전까지는 address(0), RDAO 보상 생략
    uint256 public editorRdaoReward = 30 * 1e18;   // 주에디터 RDAO 보상 (보조에디터는 절반)
    uint256 public reviewerRdaoReward = 20 * 1e18; // 리뷰어 RDAO 보상

    uint256 public reviewerQuorum = 3;
    uint256 public editorRewardPoints = 30;
    uint256 public reviewerRewardPoints = 20;
    uint256 public publishRewardPoints = 50; // 최종 채택된 제안 원저자에게

    uint256 public caseCount;
    mapping(uint256 => ReviewCase) public cases;
    mapping(uint256 => ReviewerInvite[]) public reviewersOf;
    mapping(uint256 => uint256) public acceptedReviewerCount;
    mapping(uint256 => uint256) public submittedReviewCount;

    event CaseInitiated(uint256 indexed id, CaseType caseType, uint256 sourcePostId, address indexed claimant);
    event EditorsAssigned(uint256 indexed id, address indexed chiefEditor, address indexed coEditor);
    event ReviewerInvited(uint256 indexed id, address indexed reviewer, uint256 inviteIndex);
    event ReviewerResponded(uint256 indexed id, address indexed reviewer, InviteStatus status);
    event ReviewerQuorumReached(uint256 indexed id, uint256 acceptedCount);
    event ReviewSubmitted(uint256 indexed id, address indexed reviewer, bool approve);
    event ReviewComplete(uint256 indexed id);
    event AgendaDecided(uint256 indexed id, bool adopted, uint256 approveCount, uint256 totalReviews);
    event Published(uint256 indexed id, string title, string documentURI);
    event CaseCanceled(uint256 indexed id, string reason);

    mapping(address => bool) public hasAgentRole;

    modifier onlyAgent() {
        require(hasAgentRole[msg.sender], "PeerReview: agent only");
        _;
    }
    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }
    modifier onlyCaseEditor(uint256 id) {
        ReviewCase storage c = cases[id];
        require(msg.sender == c.chiefEditor || msg.sender == c.coEditor, "PeerReview: editors only");
        _;
    }

    constructor(address badgeContract, address admin_) {
        badge = IBadgeSBTPoints2(badgeContract);
        admin = admin_;
        hasAgentRole[admin_] = true; // 초기에는 admin이 에이전트 역할 겸임 (수동 운영 가능)
    }

    // ---------------------------------------------------------------
    // 케이스 개시 / 에디터 배정 (AI 에이전트 전용)
    // ---------------------------------------------------------------

    function initiateCase(CaseType caseType, uint256 sourcePostId, address claimant, string calldata description)
        external
        onlyAgent
        returns (uint256)
    {
        require(badge.isMember(claimant), "PeerReview: claimant must be a member");
        uint256 id = ++caseCount;
        cases[id] = ReviewCase({
            id: id,
            caseType: caseType,
            sourcePostId: sourcePostId,
            claimant: claimant,
            description: description,
            chiefEditor: address(0),
            coEditor: address(0),
            status: CaseStatus.EDITOR_PENDING,
            createdAt: uint64(block.timestamp),
            publishedAt: 0,
            approveCount: 0,
            adopted: false,
            finalTitle: "",
            finalDocumentURI: "",
            finalSummary: ""
        });
        emit CaseInitiated(id, caseType, sourcePostId, claimant);
        return id;
    }

    function assignEditors(uint256 id, address chief, address coEditor_) external onlyAgent {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.EDITOR_PENDING, "PeerReview: not in EDITOR_PENDING state");
        require(badge.isMember(chief) && badge.tierOf(chief) >= 4, "PeerReview: chief editor must be Council+");
        require(badge.isMember(coEditor_), "PeerReview: co-editor must be a member");

        c.chiefEditor = chief;
        c.coEditor = coEditor_;
        c.status = CaseStatus.RECRUITING_REVIEWERS;
        emit EditorsAssigned(id, chief, coEditor_);
    }

    // ---------------------------------------------------------------
    // 리뷰어 모집 (초대 -> 수락/거절, AI 에이전트가 이메일 발송 후 응답 기록)
    // ---------------------------------------------------------------

    function inviteReviewer(uint256 id, address reviewer) external onlyAgent returns (uint256) {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.RECRUITING_REVIEWERS, "PeerReview: not recruiting reviewers");
        require(badge.isMember(reviewer), "PeerReview: reviewer must be a member");
        require(reviewer != c.chiefEditor && reviewer != c.coEditor, "PeerReview: editors cannot be reviewers");
        require(reviewer != c.claimant, "PeerReview: claimant cannot review their own case");

        ReviewerInvite[] storage list = reviewersOf[id];
        for (uint256 i = 0; i < list.length; i++) {
            require(list[i].reviewer != reviewer, "PeerReview: already invited");
        }

        list.push(ReviewerInvite({
            reviewer: reviewer,
            status: InviteStatus.INVITED,
            invitedAt: uint64(block.timestamp),
            respondedAt: 0,
            reviewSubmitted: false,
            approve: false,
            reviewURI: ""
        }));
        uint256 idx = list.length - 1;
        emit ReviewerInvited(id, reviewer, idx);
        return idx;
    }

    /// @notice 초대 메일의 수락/거절 버튼 클릭 결과를 에이전트가 기록한다.
    function recordReviewerResponse(uint256 id, uint256 inviteIndex, bool accepted) external onlyAgent {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.RECRUITING_REVIEWERS || c.status == CaseStatus.IN_REVIEW, "PeerReview: invalid case status");
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.status == InviteStatus.INVITED, "PeerReview: invite already resolved");

        inv.status = accepted ? InviteStatus.ACCEPTED : InviteStatus.DECLINED;
        inv.respondedAt = uint64(block.timestamp);
        emit ReviewerResponded(id, inv.reviewer, inv.status);

        if (accepted) {
            acceptedReviewerCount[id] += 1;
            if (acceptedReviewerCount[id] == reviewerQuorum && c.status == CaseStatus.RECRUITING_REVIEWERS) {
                c.status = CaseStatus.IN_REVIEW;
                emit ReviewerQuorumReached(id, acceptedReviewerCount[id]);
            }
        }
    }

    /// @notice 일정 기간 응답이 없는 초대를 타임아웃 처리한다 (에이전트가 스케줄러로 호출).
    function markInviteTimedOut(uint256 id, uint256 inviteIndex) external onlyAgent {
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.status == InviteStatus.INVITED, "PeerReview: invite already resolved");
        inv.status = InviteStatus.TIMED_OUT;
        inv.respondedAt = uint64(block.timestamp);
        emit ReviewerResponded(id, inv.reviewer, InviteStatus.TIMED_OUT);
    }

    // ---------------------------------------------------------------
    // 리뷰 제출 / 완료
    // ---------------------------------------------------------------

    /// @notice 수락한 리뷰어가 (비공개 질의응답을 마친 뒤) 최종 리뷰 의견과 찬성/반대 판정을 제출한다.
    ///         전체 리뷰가 정족수만큼 모이면, 찬성이 2/3 이상일 때만 "의안상정"으로 자동 전환되고
    ///         그렇지 않으면 "의안상정보류" 상태가 되어 발행이 불가능해진다.
    function submitReview(uint256 id, uint256 inviteIndex, string calldata reviewURI, bool approve) external {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.IN_REVIEW, "PeerReview: case not in review");
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.reviewer == msg.sender, "PeerReview: not your invite slot");
        require(inv.status == InviteStatus.ACCEPTED, "PeerReview: you have not accepted this invite");
        require(!inv.reviewSubmitted, "PeerReview: review already submitted");

        inv.reviewSubmitted = true;
        inv.reviewURI = reviewURI;
        inv.approve = approve;
        submittedReviewCount[id] += 1;
        if (approve) c.approveCount += 1;
        emit ReviewSubmitted(id, msg.sender, approve);

        if (submittedReviewCount[id] >= reviewerQuorum) {
            emit ReviewComplete(id);
            // 2/3 이상 찬성이어야 의안상정 (정수 연산: approveCount*3 >= quorum*2)
            if (c.approveCount * 3 >= reviewerQuorum * 2) {
                c.status = CaseStatus.AGENDA_ADOPTED;
                c.adopted = true;
            } else {
                c.status = CaseStatus.AGENDA_PENDING;
                c.adopted = false;
            }
            emit AgendaDecided(id, c.adopted, c.approveCount, submittedReviewCount[id]);
        }
    }

    // ---------------------------------------------------------------
    // 최종 발행 (에디터 전용, 투표 불필요 — 즉시 온체인 반영)
    // ---------------------------------------------------------------

    function publishFinalProposal(
        uint256 id,
        string calldata title,
        string calldata documentURI,
        string calldata summary
    ) external onlyCaseEditor(id) {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.AGENDA_ADOPTED, "PeerReview: only adopted agendas (2/3+ approve) can be published");
        require(bytes(title).length > 0 && bytes(documentURI).length > 0, "title/documentURI required");

        c.status = CaseStatus.PUBLISHED;
        c.publishedAt = uint64(block.timestamp);
        c.finalTitle = title;
        c.finalDocumentURI = documentURI;
        c.finalSummary = summary;
        emit Published(id, title, documentURI);

        // 포인트 지급: 원저자, 에디터 2인, 리뷰 제출한 리뷰어 전원
        badge.addPoints(c.claimant, int256(publishRewardPoints), "peer-reviewed policy proposal published");
        badge.addPoints(c.chiefEditor, int256(editorRewardPoints), "served as chief editor");
        badge.addPoints(c.coEditor, int256(editorRewardPoints / 2), "served as co-editor");

        ReviewerInvite[] storage list = reviewersOf[id];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].reviewSubmitted) {
                badge.addPoints(list[i].reviewer, int256(reviewerRewardPoints), "completed peer review");
            }
        }

        // RDAO 보상 지급 (rdaoToken이 설정된 경우에만 — 미설정 시 조용히 생략)
        if (address(rdaoToken) != address(0)) {
            rdaoToken.mint(c.chiefEditor, editorRdaoReward);
            rdaoToken.mint(c.coEditor, editorRdaoReward / 2);
            for (uint256 i = 0; i < list.length; i++) {
                if (list[i].reviewSubmitted) {
                    rdaoToken.mint(list[i].reviewer, reviewerRdaoReward);
                }
            }
        }
    }

    function cancelCase(uint256 id, string calldata reason) external onlyAgent {
        ReviewCase storage c = cases[id];
        require(c.status != CaseStatus.PUBLISHED, "PeerReview: already published");
        c.status = CaseStatus.CANCELED;
        emit CaseCanceled(id, reason);
    }

    // ---------------------------------------------------------------
    // 조회
    // ---------------------------------------------------------------

    function reviewersCount(uint256 id) external view returns (uint256) {
        return reviewersOf[id].length;
    }

    // ---------------------------------------------------------------
    // 관리
    // ---------------------------------------------------------------

    function setAgent(address agent, bool enabled) external onlyAdmin {
        hasAgentRole[agent] = enabled;
    }
    function setReviewerQuorum(uint256 v) external onlyAdmin { reviewerQuorum = v; }
    function setRdaoToken(address token) external onlyAdmin { rdaoToken = IRDAOMintable(token); }
    function setEditorRdaoReward(uint256 v) external onlyAdmin { editorRdaoReward = v; }
    function setReviewerRdaoReward(uint256 v) external onlyAdmin { reviewerRdaoReward = v; }
    function setEditorRewardPoints(uint256 v) external onlyAdmin { editorRewardPoints = v; }
    function setReviewerRewardPoints(uint256 v) external onlyAdmin { reviewerRewardPoints = v; }
    function setPublishRewardPoints(uint256 v) external onlyAdmin { publishRewardPoints = v; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
