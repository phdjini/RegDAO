// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBadgeSBTPoints2 {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
    function addPoints(address member, int256 delta, string calldata reason) external;
}

interface IRDAOToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IProposalBoardRef {
    function isReferred(uint256 postId) external view returns (bool);
    function authorOf(uint256 postId) external view returns (address);
}

/**
 * @title PeerReview
 * @notice Expert peer review of referred policy proposals (manuscript Sections IV-D, Appendix A-3).
 *
 *  Flow: case opened for a referred proposal (or an achievement claim)
 *        -> AI agent assigns lead and associate editors (both Council+)
 *        -> each editor accepts on-chain and stakes S_PPR
 *        -> agent invites reviewers (Member-Gold+); each accepting reviewer stakes S_PPR
 *        -> once reviewerQuorum reviewers have accepted, review opens with a deadline
 *        -> when all panel reviews are in, the case is AGENDA_ADOPTED if approvals >= 2/3, else AGENDA_PENDING
 *        -> every panelist who did their part gets the deposit back plus points and RDAO, regardless of verdict
 *        -> an accepted reviewer who misses the deadline is a no-show: part of the deposit is burned
 *
 *  The agent records off-chain judgements (matching, invitations, declines); verdicts and deposits are on-chain.
 */
contract PeerReview {
    enum CaseType { POLICY_PROPOSAL, ACHIEVEMENT }
    enum CaseStatus { EDITOR_PENDING, RECRUITING_REVIEWERS, IN_REVIEW, AGENDA_ADOPTED, AGENDA_PENDING, PUBLISHED, CANCELED }
    enum InviteStatus { INVITED, ACCEPTED, DECLINED, TIMED_OUT, NO_SHOW }

    uint8 public constant EDITOR_MIN_TIER = 4;   // Council
    uint8 public constant REVIEWER_MIN_TIER = 3; // Member-Gold

    struct ReviewCase {
        uint256 id;
        CaseType caseType;
        uint256 sourcePostId;
        address claimant;
        string description;
        address chiefEditor;
        address coEditor;
        CaseStatus status;
        uint64 createdAt;
        uint64 publishedAt;
        uint256 approveCount;
        bool adopted;
        string finalTitle;
        string finalDocumentURI;
        string finalSummary;
    }

    struct EditorState {
        bool chiefAccepted;
        bool coAccepted;
        uint256 chiefStake;
        uint256 coStake;
        uint64 reviewDeadline;
    }

    struct ReviewerInvite {
        address reviewer;
        InviteStatus status;
        uint64 invitedAt;
        uint64 respondedAt;
        bool reviewSubmitted;
        bool approve;
        string reviewURI;
        uint256 stake;
    }

    IBadgeSBTPoints2 public immutable badge;
    IRDAOToken public immutable rdaoToken;
    IProposalBoardRef public board;
    address public admin;

    uint256 public reviewerQuorum = 3;
    uint256 public panelStake = 10 ether;          // S_PPR
    uint64 public reviewPeriod = 14 days;
    uint256 public noShowBurnBps = 5000;           // share of S_PPR burned for a no-show
    uint256 public editorRdaoReward = 30 ether;    // lead editor (associate editor gets half)
    uint256 public reviewerRdaoReward = 20 ether;
    uint256 public editorRewardPoints = 30;
    uint256 public reviewerRewardPoints = 20;
    uint256 public publishRewardPoints = 50;       // to the original proposer when the final proposal is published

    uint256 public caseCount;
    mapping(uint256 => ReviewCase) public cases;
    mapping(uint256 => EditorState) public editorState;
    mapping(uint256 => ReviewerInvite[]) public reviewersOf;
    mapping(uint256 => uint256) public acceptedReviewerCount;
    mapping(uint256 => uint256) public submittedReviewCount;
    mapping(uint256 => uint256) public caseOfPost;
    mapping(address => bool) public hasAgentRole;

    event CaseInitiated(uint256 indexed id, CaseType caseType, uint256 sourcePostId, address indexed claimant);
    event EditorsAssigned(uint256 indexed id, address indexed chiefEditor, address indexed coEditor);
    event EditorAccepted(uint256 indexed id, address indexed editor, uint256 stake);
    event ReviewerInvited(uint256 indexed id, address indexed reviewer, uint256 inviteIndex);
    event ReviewerResponded(uint256 indexed id, address indexed reviewer, InviteStatus status);
    event ReviewerQuorumReached(uint256 indexed id, uint256 acceptedCount, uint64 deadline);
    event ReviewSubmitted(uint256 indexed id, address indexed reviewer, bool approve);
    event ReviewComplete(uint256 indexed id);
    event AgendaDecided(uint256 indexed id, bool adopted, uint256 approveCount, uint256 totalReviews);
    event PanelPaid(uint256 indexed id, address indexed member, uint256 refunded, uint256 rdaoReward, uint256 points);
    event NoShow(uint256 indexed id, address indexed reviewer, uint256 burned, uint256 refunded);
    event Published(uint256 indexed id, string title, string documentURI);
    event CaseCanceled(uint256 indexed id, string reason);

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

    constructor(address badgeContract, address rdao, address admin_) {
        badge = IBadgeSBTPoints2(badgeContract);
        rdaoToken = IRDAOToken(rdao);
        admin = admin_;
        hasAgentRole[admin_] = true;
    }

    // ---------------------------------------------------------------
    // Case opening and editors
    // ---------------------------------------------------------------

    function initiateCase(CaseType caseType, uint256 sourcePostId, address claimant, string calldata description)
        external
        onlyAgent
        returns (uint256)
    {
        require(badge.isMember(claimant), "PeerReview: claimant must be a member");
        if (caseType == CaseType.POLICY_PROPOSAL) {
            require(address(board) != address(0), "PeerReview: board not set");
            require(board.isReferred(sourcePostId), "PeerReview: proposal has not reached theta_PR");
            require(board.authorOf(sourcePostId) == claimant, "PeerReview: claimant must be the proposer");
            require(caseOfPost[sourcePostId] == 0, "PeerReview: case already exists for this proposal");
        }
        uint256 id = ++caseCount;
        ReviewCase storage c = cases[id];
        c.id = id;
        c.caseType = caseType;
        c.sourcePostId = sourcePostId;
        c.claimant = claimant;
        c.description = description;
        c.status = CaseStatus.EDITOR_PENDING;
        c.createdAt = uint64(block.timestamp);
        if (caseType == CaseType.POLICY_PROPOSAL) caseOfPost[sourcePostId] = id;
        emit CaseInitiated(id, caseType, sourcePostId, claimant);
        return id;
    }

    /// @notice Assigns (or re-assigns, for slots not yet accepted) the lead and associate editors.
    function assignEditors(uint256 id, address chief, address coEditor_) external onlyAgent {
        ReviewCase storage c = cases[id];
        EditorState storage s = editorState[id];
        require(c.status == CaseStatus.EDITOR_PENDING, "PeerReview: not in EDITOR_PENDING state");
        require(chief != coEditor_, "PeerReview: editors must differ");
        require(chief != c.claimant && coEditor_ != c.claimant, "PeerReview: claimant cannot edit own case");
        require(badge.isMember(chief) && badge.tierOf(chief) >= EDITOR_MIN_TIER, "PeerReview: chief editor must be Council+");
        require(badge.isMember(coEditor_) && badge.tierOf(coEditor_) >= EDITOR_MIN_TIER, "PeerReview: co-editor must be Council+");
        if (s.chiefAccepted) require(chief == c.chiefEditor, "PeerReview: chief editor already accepted");
        if (s.coAccepted) require(coEditor_ == c.coEditor, "PeerReview: co-editor already accepted");
        c.chiefEditor = chief;
        c.coEditor = coEditor_;
        emit EditorsAssigned(id, chief, coEditor_);
    }

    /// @notice An assigned editor accepts the role and stakes S_PPR.
    function acceptEditorship(uint256 id) external {
        ReviewCase storage c = cases[id];
        EditorState storage s = editorState[id];
        require(c.status == CaseStatus.EDITOR_PENDING, "PeerReview: not in EDITOR_PENDING state");
        if (msg.sender == c.chiefEditor) {
            require(!s.chiefAccepted, "PeerReview: already accepted");
            s.chiefAccepted = true;
            s.chiefStake = panelStake;
        } else if (msg.sender == c.coEditor) {
            require(!s.coAccepted, "PeerReview: already accepted");
            s.coAccepted = true;
            s.coStake = panelStake;
        } else {
            revert("PeerReview: not an assigned editor");
        }
        _pull(msg.sender, panelStake);
        emit EditorAccepted(id, msg.sender, panelStake);
        if (s.chiefAccepted && s.coAccepted) c.status = CaseStatus.RECRUITING_REVIEWERS;
    }

    // ---------------------------------------------------------------
    // Reviewers
    // ---------------------------------------------------------------

    function inviteReviewer(uint256 id, address reviewer) external onlyAgent returns (uint256) {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.RECRUITING_REVIEWERS, "PeerReview: not recruiting reviewers");
        require(badge.isMember(reviewer) && badge.tierOf(reviewer) >= REVIEWER_MIN_TIER, "PeerReview: reviewer must be Member-Gold+");
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
            reviewURI: "",
            stake: 0
        }));
        uint256 idx = list.length - 1;
        emit ReviewerInvited(id, reviewer, idx);
        return idx;
    }

    /// @notice The invited reviewer accepts on-chain and stakes S_PPR.
    function acceptInvite(uint256 id, uint256 inviteIndex) external {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.RECRUITING_REVIEWERS, "PeerReview: not recruiting reviewers");
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.reviewer == msg.sender, "PeerReview: not your invite slot");
        require(inv.status == InviteStatus.INVITED, "PeerReview: invite already resolved");
        require(acceptedReviewerCount[id] < reviewerQuorum, "PeerReview: panel already full");

        inv.status = InviteStatus.ACCEPTED;
        inv.respondedAt = uint64(block.timestamp);
        inv.stake = panelStake;
        _pull(msg.sender, panelStake);
        emit ReviewerResponded(id, msg.sender, InviteStatus.ACCEPTED);

        acceptedReviewerCount[id] += 1;
        if (acceptedReviewerCount[id] == reviewerQuorum) {
            c.status = CaseStatus.IN_REVIEW;
            uint64 deadline = uint64(block.timestamp) + reviewPeriod;
            editorState[id].reviewDeadline = deadline;
            emit ReviewerQuorumReached(id, acceptedReviewerCount[id], deadline);
        }
    }

    /// @notice The invited reviewer (or the agent, relaying an e-mail reply) declines.
    function declineInvite(uint256 id, uint256 inviteIndex) external {
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.reviewer == msg.sender || hasAgentRole[msg.sender], "PeerReview: not allowed");
        require(inv.status == InviteStatus.INVITED, "PeerReview: invite already resolved");
        inv.status = InviteStatus.DECLINED;
        inv.respondedAt = uint64(block.timestamp);
        emit ReviewerResponded(id, inv.reviewer, InviteStatus.DECLINED);
    }

    function markInviteTimedOut(uint256 id, uint256 inviteIndex) external onlyAgent {
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.status == InviteStatus.INVITED, "PeerReview: invite already resolved");
        inv.status = InviteStatus.TIMED_OUT;
        inv.respondedAt = uint64(block.timestamp);
        emit ReviewerResponded(id, inv.reviewer, InviteStatus.TIMED_OUT);
    }

    /// @notice After the deadline, anyone may mark an accepted reviewer who has not submitted as a no-show.
    ///         Part of the deposit is burned, the seat reopens, and the agent can invite a replacement.
    function markNoShow(uint256 id, uint256 inviteIndex) external {
        ReviewCase storage c = cases[id];
        require(c.status == CaseStatus.IN_REVIEW, "PeerReview: case not in review");
        require(block.timestamp > editorState[id].reviewDeadline, "PeerReview: deadline not passed");
        ReviewerInvite storage inv = reviewersOf[id][inviteIndex];
        require(inv.status == InviteStatus.ACCEPTED && !inv.reviewSubmitted, "PeerReview: not a no-show");

        inv.status = InviteStatus.NO_SHOW;
        uint256 burnAmt = (inv.stake * noShowBurnBps) / 10000;
        uint256 refund = inv.stake - burnAmt;
        inv.stake = 0;
        if (burnAmt > 0) rdaoToken.burn(burnAmt);
        if (refund > 0) require(rdaoToken.transfer(inv.reviewer, refund), "PeerReview: refund failed");
        emit NoShow(id, inv.reviewer, burnAmt, refund);

        acceptedReviewerCount[id] -= 1;
        c.status = CaseStatus.RECRUITING_REVIEWERS;
    }

    // ---------------------------------------------------------------
    // Reviews and verdict
    // ---------------------------------------------------------------

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
            // Eq. (5): adopted iff approvals / quorum >= 2/3
            c.adopted = c.approveCount * 3 >= reviewerQuorum * 2;
            c.status = c.adopted ? CaseStatus.AGENDA_ADOPTED : CaseStatus.AGENDA_PENDING;
            emit AgendaDecided(id, c.adopted, c.approveCount, submittedReviewCount[id]);
            _payPanel(id);
        }
    }

    /// @dev Panel immunity (Appendix A-3): deposit refund, points and RDAO regardless of verdict direction.
    function _payPanel(uint256 id) internal {
        ReviewCase storage c = cases[id];
        EditorState storage s = editorState[id];

        _payMember(id, c.chiefEditor, s.chiefStake, editorRdaoReward, editorRewardPoints, "served as lead editor");
        s.chiefStake = 0;
        _payMember(id, c.coEditor, s.coStake, editorRdaoReward / 2, editorRewardPoints / 2, "served as associate editor");
        s.coStake = 0;

        ReviewerInvite[] storage list = reviewersOf[id];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].reviewSubmitted) {
                uint256 stake = list[i].stake;
                list[i].stake = 0;
                _payMember(id, list[i].reviewer, stake, reviewerRdaoReward, reviewerRewardPoints, "completed peer review");
            }
        }
    }

    function _payMember(uint256 id, address member, uint256 stake, uint256 reward, uint256 pts, string memory reason) internal {
        if (stake > 0) require(rdaoToken.transfer(member, stake), "PeerReview: refund failed");
        if (reward > 0) rdaoToken.mint(member, reward);
        if (pts > 0 && badge.isMember(member)) badge.addPoints(member, int256(pts), reason);
        emit PanelPaid(id, member, stake, reward, pts);
    }

    // ---------------------------------------------------------------
    // Publication (editors only, no further vote)
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

        if (badge.isMember(c.claimant)) {
            badge.addPoints(c.claimant, int256(publishRewardPoints), "peer-reviewed policy proposal published");
        }
    }

    /// @notice Cancels an undecided case and returns every outstanding panel deposit without reward.
    function cancelCase(uint256 id, string calldata reason) external onlyAgent {
        ReviewCase storage c = cases[id];
        require(
            c.status == CaseStatus.EDITOR_PENDING || c.status == CaseStatus.RECRUITING_REVIEWERS || c.status == CaseStatus.IN_REVIEW,
            "PeerReview: case already decided"
        );
        c.status = CaseStatus.CANCELED;
        if (c.caseType == CaseType.POLICY_PROPOSAL) caseOfPost[c.sourcePostId] = 0;

        EditorState storage s = editorState[id];
        if (s.chiefStake > 0) { uint256 a = s.chiefStake; s.chiefStake = 0; require(rdaoToken.transfer(c.chiefEditor, a), "refund failed"); }
        if (s.coStake > 0) { uint256 b = s.coStake; s.coStake = 0; require(rdaoToken.transfer(c.coEditor, b), "refund failed"); }
        ReviewerInvite[] storage list = reviewersOf[id];
        for (uint256 i = 0; i < list.length; i++) {
            uint256 st = list[i].stake;
            if (st > 0) {
                list[i].stake = 0;
                require(rdaoToken.transfer(list[i].reviewer, st), "refund failed");
            }
        }
        emit CaseCanceled(id, reason);
    }

    function _pull(address from, uint256 amount) internal {
        if (amount > 0) require(rdaoToken.transferFrom(from, address(this), amount), "PeerReview: stake transfer failed");
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function reviewersCount(uint256 id) external view returns (uint256) {
        return reviewersOf[id].length;
    }

    function outcomeOf(uint256 caseId) external view returns (uint8 caseType, uint256 sourcePostId, uint8 status) {
        ReviewCase storage c = cases[caseId];
        return (uint8(c.caseType), c.sourcePostId, uint8(c.status));
    }

    // ---------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------

    function setAgent(address agent, bool enabled) external onlyAdmin { hasAgentRole[agent] = enabled; }
    function setBoard(address b) external onlyAdmin { board = IProposalBoardRef(b); }
    function setReviewerQuorum(uint256 v) external onlyAdmin { require(v > 0, "invalid quorum"); reviewerQuorum = v; }
    function setPanelStake(uint256 v) external onlyAdmin { panelStake = v; }
    function setReviewPeriod(uint64 v) external onlyAdmin { reviewPeriod = v; }
    function setNoShowBurnBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); noShowBurnBps = v; }
    function setEditorRdaoReward(uint256 v) external onlyAdmin { editorRdaoReward = v; }
    function setReviewerRdaoReward(uint256 v) external onlyAdmin { reviewerRdaoReward = v; }
    function setEditorRewardPoints(uint256 v) external onlyAdmin { editorRewardPoints = v; }
    function setReviewerRewardPoints(uint256 v) external onlyAdmin { reviewerRewardPoints = v; }
    function setPublishRewardPoints(uint256 v) external onlyAdmin { publishRewardPoints = v; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
