// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBadgeSBTPoints {
    function isMember(address member) external view returns (bool);
    function tierOf(address member) external view returns (uint8);
    function addPoints(address member, int256 delta, string calldata reason) external;
    function memberCount() external view returns (uint256);
}

interface IRDAO is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IPeerReviewOutcome {
    /// @return caseType 0 = POLICY_PROPOSAL
    /// @return sourcePostId the ProposalBoard post under review
    /// @return status PeerReview.CaseStatus (3 AGENDA_ADOPTED, 4 AGENDA_PENDING, 5 PUBLISHED)
    /// @return decidedAt  timestamp at which the verdict was reached (0 if undecided)
    function outcomeOf(uint256 caseId)
        external
        view
        returns (uint8 caseType, uint256 sourcePostId, uint8 status, uint64 decidedAt);
}

/**
 * @title ProposalBoard
 * @notice Policy-proposal board implementing the RegDAO verification and incentive model
 *         (manuscript Sections IV-C, IV-D1, IV-E and Appendix A).
 *
 *  1) Reasoned endorsement (RE): support or opposition must carry a reason; one RE per member per proposal.
 *  2) Formality compliance check (FCC): an off-chain checker (FCC_AGENT) evaluates checklist items C1..C6
 *     and records the result as a 6-bit mask. score(e) = popcount(mask); FCC(e) = 1 iff score >= tauFCC (= 6).
 *     The direction of the RE never enters the check. The mask is stored on-chain for post-hoc audit.
 *  3) Pre-verification points: each passing RE pays dP_RE to the endorser and, on the first passing RE only,
 *     dP_PRO to the proposer. Points are never reclaimed.
 *  4) Referral: once N_RE(p) >= theta_PR = max(theta_min, ceil(rho * |M|)), the proposal is marked referred and
 *     PeerReview may open a case for it.
 *  5) Mandatory pre-staking: S_PRO at proposal submission, S_RE per RE.
 *  6) Settlement on the peer-review verdict:
 *       approved  -> every participant gets the full deposit back plus an RDAO reward;
 *       rejected  -> proposer and supporting endorsers are slashed by lambda(n), where n is their cumulative
 *                    rejection count within the trailing window (default 90 days); endorsers who opposed
 *                    beforehand are refunded in full, but their dP_RE is clawed back so that opposing stakes
 *                    cannot serve a coalition as a zero-risk hedge. An opposing RE whose author the agent has
 *                    flagged for dense prior interaction with the proposer loses the exemption and is slashed.
 *     REs that did not pass FCC are refunded in full and earn nothing.
 *  7) Non-referral sunset: a proposal that does not reach theta_PR within T_TTL expires; the proposer and the
 *     FCC-passed supporting endorsers lose lambda_idle of their deposits, everyone else is refunded.
 *  8) Settlement window: after a verdict the agent may settle at once; anyone else may settle after
 *     settleDelay, which leaves the agent time to record exemption revocations.
 */
contract ProposalBoard {
    enum Category { REGULATION, INDUSTRY_PAIN_POINT, SPEAKER_INVITATION, MEDIA_CONTRIBUTION, OTHER }
    enum FCCStatus { PENDING, PASSED, FAILED }
    enum Outcome { OPEN, ADOPTED, REJECTED, EXPIRED }

    struct Post {
        uint256 id;
        address author;
        Category category;
        string title;
        string content;
        string attachmentURI;
        uint64 createdAt;
        uint256 supportCount;   // FCC-passed supporting REs
        uint256 opposeCount;    // FCC-passed opposing REs
        uint256 verifiedCount;  // N_RE(p) = supportCount + opposeCount
        uint256 stake;          // S_PRO held for this proposal
        bool proposerAwarded;   // dP_PRO already paid (once per proposal)
        bool referred;          // N_RE(p) reached theta_PR
        Outcome outcome;
        bool exists;
    }

    struct Comment {
        uint256 id;
        uint256 postId;
        address author;
        string content;
        uint64 createdAt;
        bool exists;
    }

    struct Endorsement {
        uint256 id;
        uint256 postId;
        address endorser;
        bool isSupport;
        string reason;
        FCCStatus fcc;
        uint8 fccMask;          // bit k-1 set <=> checklist item C_k satisfied
        bool appealed;
        uint256 stake;          // S_RE held for this RE
        uint64 createdAt;
        bool exists;
    }

    uint8 public constant FCC_ITEMS = 6;
    uint256 public constant MIN_REASON_BYTES = 50; // on-chain floor for C1; the checker applies the character rule

    IBadgeSBTPoints public immutable badge;
    IRDAO public immutable rdao;
    IPeerReviewOutcome public peerReview;
    address public admin;
    mapping(address => bool) public isFccAgent;

    // --- parameters (manuscript notation) ---
    uint8 public tauFCC = 6;                        // tau_FCC
    uint256 public pointsProposer = 3;              // dP_PRO
    uint256 public pointsEndorser = 2;              // dP_RE
    uint256 public thetaMin = 3;                    // theta_min
    uint256 public rhoBps = 500;                    // rho (basis points of |M|)
    uint256 public stakeProposer = 30 ether;        // S_PRO (RDAO, 18 decimals)
    uint256 public stakeEndorser = 20 ether;        // S_RE
    uint256 public rewardProposer = 20 ether;       // RDAO reward on approval
    uint256 public rewardEndorser = 5 ether;        // RDAO reward on approval (per FCC-passed RE)
    uint16[] public burnScheduleBps;                // lambda(1), lambda(2), ...; last value repeats
    uint64 public rejectionWindow = 90 days;
    uint64 public postExpiry = 90 days;             // T_TTL: un-referred proposals expire after this
    uint256 public idleBurnBps = 2000;              // lambda_idle: share of deposits burned on expiry
    uint64 public settleDelay = 1 days;             // public settlement opens this long after the verdict
    uint256 public maxEndorsementsPerPost = 100;    // bounds settlement gas
    uint8 public minPostTier = 0;

    uint256 public postCount;
    uint256 public commentCount;
    uint256 public endorsementCount;

    mapping(uint256 => Post) public posts;
    mapping(uint256 => Comment) public comments;
    mapping(uint256 => Endorsement) public endorsements;
    mapping(uint256 => uint256[]) private _postEndorsements;
    mapping(uint256 => mapping(address => bool)) public hasEndorsed;
    mapping(address => uint64[]) private _rejections; // timestamps of rejections that triggered slashing review
    mapping(uint256 => uint256) public awardedPoints;      // dP_RE actually paid for an RE (for clawback)
    mapping(uint256 => bool) public exemptionRevoked;      // opposing RE flagged for dense interaction with the proposer

    event PostCreated(uint256 indexed id, address indexed author, Category category, string title, uint256 stake);
    event CommentCreated(uint256 indexed id, uint256 indexed postId, address indexed author);
    event EndorsementCreated(uint256 indexed id, uint256 indexed postId, address indexed endorser, bool isSupport, uint256 stake);
    event FCCRecorded(uint256 indexed endorsementId, uint8 mask, uint8 score, bool passed);
    event FCCAppealed(uint256 indexed endorsementId);
    event PreVerificationPoints(uint256 indexed postId, address indexed member, uint256 points, bool proposer);
    event ReferredToPeerReview(uint256 indexed postId, uint256 verifiedCount, uint256 threshold);
    event Settled(uint256 indexed postId, uint256 indexed caseId, Outcome outcome);
    event StakeResolved(uint256 indexed postId, address indexed member, uint256 refunded, uint256 burned, uint256 reward, uint256 rejectionCount);
    event PointsClawedBack(uint256 indexed endorsementId, address indexed member, uint256 points);
    event ExemptionRevoked(uint256 indexed endorsementId, string evidence);

    modifier onlyMember() {
        require(badge.isMember(msg.sender), "ProposalBoard: badge holders only");
        _;
    }
    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }
    modifier onlyFccAgent() {
        require(isFccAgent[msg.sender], "ProposalBoard: FCC agent only");
        _;
    }

    constructor(address badgeContract, address rdaoToken, address admin_) {
        badge = IBadgeSBTPoints(badgeContract);
        rdao = IRDAO(rdaoToken);
        admin = admin_;
        isFccAgent[admin_] = true;
        burnScheduleBps.push(0);      // lambda(1) = 0%  (first-occurrence grace)
        burnScheduleBps.push(3000);   // lambda(2) = 30%
        burnScheduleBps.push(6000);   // lambda(3) = 60%
        burnScheduleBps.push(10000);  // lambda(n>=4) = 100%
    }

    // ---------------------------------------------------------------
    // Proposals and comments
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
        Post storage p = posts[id];
        p.id = id;
        p.author = msg.sender;
        p.category = category;
        p.title = title;
        p.content = content;
        p.attachmentURI = attachmentURI;
        p.createdAt = uint64(block.timestamp);
        p.stake = stakeProposer;
        p.exists = true;

        _pull(msg.sender, stakeProposer);
        emit PostCreated(id, msg.sender, category, title, stakeProposer);
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
            exists: true
        });
        emit CommentCreated(id, postId, msg.sender);
        return id;
    }

    // ---------------------------------------------------------------
    // Reasoned endorsement (stage 1)
    // ---------------------------------------------------------------

    function endorsePost(uint256 postId, bool isSupport, string calldata reason) external onlyMember returns (uint256) {
        Post storage p = posts[postId];
        require(p.exists, "ProposalBoard: post does not exist");
        require(p.outcome == Outcome.OPEN, "ProposalBoard: proposal already closed");
        require(p.author != msg.sender, "cannot endorse your own post");
        require(badge.tierOf(msg.sender) >= 1, "ProposalBoard: endorser must be Member-Bronze+");
        require(!hasEndorsed[postId][msg.sender], "ProposalBoard: you already endorsed this");
        require(bytes(reason).length >= MIN_REASON_BYTES, "ProposalBoard: a substantive reason is required");
        require(_postEndorsements[postId].length < maxEndorsementsPerPost, "ProposalBoard: endorsement cap reached");

        hasEndorsed[postId][msg.sender] = true;
        uint256 id = ++endorsementCount;
        endorsements[id] = Endorsement({
            id: id,
            postId: postId,
            endorser: msg.sender,
            isSupport: isSupport,
            reason: reason,
            fcc: FCCStatus.PENDING,
            fccMask: 0,
            appealed: false,
            stake: stakeEndorser,
            createdAt: uint64(block.timestamp),
            exists: true
        });
        _postEndorsements[postId].push(id);

        _pull(msg.sender, stakeEndorser);
        emit EndorsementCreated(id, postId, msg.sender, isSupport, stakeEndorser);
        return id;
    }

    // ---------------------------------------------------------------
    // Formality compliance check (stage 2)
    // ---------------------------------------------------------------

    /// @notice Records the checklist result for one RE. Bits 0..5 correspond to C1..C6.
    function recordFCC(uint256 endorsementId, uint8 mask) external onlyFccAgent {
        Endorsement storage e = endorsements[endorsementId];
        require(e.exists, "ProposalBoard: endorsement does not exist");
        require(e.fcc == FCCStatus.PENDING, "ProposalBoard: FCC already recorded");
        Post storage p = posts[e.postId];
        require(p.outcome == Outcome.OPEN, "ProposalBoard: proposal already closed");

        mask &= uint8((1 << FCC_ITEMS) - 1);
        uint8 score = _popcount(mask);
        bool passed = score >= tauFCC;
        e.fccMask = mask;
        e.fcc = passed ? FCCStatus.PASSED : FCCStatus.FAILED;
        emit FCCRecorded(endorsementId, mask, score, passed);
        if (!passed) return;

        if (e.isSupport) p.supportCount += 1;
        else p.opposeCount += 1;
        p.verifiedCount += 1;

        awardedPoints[endorsementId] = pointsEndorser;
        badge.addPoints(e.endorser, int256(pointsEndorser), "FCC-verified reasoned endorsement");
        emit PreVerificationPoints(e.postId, e.endorser, pointsEndorser, false);
        if (!p.proposerAwarded) {
            p.proposerAwarded = true;
            badge.addPoints(p.author, int256(pointsProposer), "proposal received first verified endorsement");
            emit PreVerificationPoints(e.postId, p.author, pointsProposer, true);
        }

        if (!p.referred) {
            uint256 threshold = referralThreshold();
            if (p.verifiedCount >= threshold) {
                p.referred = true;
                emit ReferredToPeerReview(e.postId, p.verifiedCount, threshold);
            }
        }
    }

    /// @notice An endorser whose RE failed FCC may request one re-adjudication.
    function appealFCC(uint256 endorsementId) external {
        Endorsement storage e = endorsements[endorsementId];
        require(e.endorser == msg.sender, "ProposalBoard: not your endorsement");
        require(e.fcc == FCCStatus.FAILED, "ProposalBoard: only failed REs can be appealed");
        require(!e.appealed, "ProposalBoard: already appealed");
        require(posts[e.postId].outcome == Outcome.OPEN, "ProposalBoard: proposal already closed");
        e.appealed = true;
        e.fcc = FCCStatus.PENDING;
        emit FCCAppealed(endorsementId);
    }

    /// @notice The agent flags an opposing RE whose author interacts densely with the proposer (interaction-graph
    ///         check, Section IV-D1). A flagged RE loses the slashing exemption if the proposal is rejected.
    function revokeExemption(uint256 endorsementId, string calldata evidence) external onlyFccAgent {
        Endorsement storage e = endorsements[endorsementId];
        require(e.exists && !e.isSupport, "ProposalBoard: only opposing REs carry an exemption");
        require(posts[e.postId].outcome == Outcome.OPEN, "ProposalBoard: proposal already closed");
        exemptionRevoked[endorsementId] = true;
        emit ExemptionRevoked(endorsementId, evidence);
    }

    /// @notice theta_PR = max(theta_min, ceil(rho * |M|)).
    function referralThreshold() public view returns (uint256) {
        uint256 scaled = (rhoBps * badge.memberCount() + 9999) / 10000;
        return scaled > thetaMin ? scaled : thetaMin;
    }

    // ---------------------------------------------------------------
    // Settlement on the peer-review verdict
    // ---------------------------------------------------------------

    /// @notice Anyone may settle a referred proposal once PeerReview has decided its case.
    function settle(uint256 postId, uint256 caseId) external {
        Post storage p = posts[postId];
        require(p.exists && p.referred, "ProposalBoard: proposal not referred");
        require(p.outcome == Outcome.OPEN, "ProposalBoard: already settled");
        require(address(peerReview) != address(0), "ProposalBoard: peer review not set");
        (uint8 caseType, uint256 sourcePostId, uint8 status, uint64 decidedAt) = peerReview.outcomeOf(caseId);
        require(caseType == 0 && sourcePostId == postId, "ProposalBoard: case does not match proposal");
        require(status == 3 || status == 4 || status == 5, "ProposalBoard: verdict not final");
        require(
            isFccAgent[msg.sender] || block.timestamp >= uint256(decidedAt) + settleDelay,
            "ProposalBoard: settlement window not yet open"
        );

        bool adopted = status != 4;
        p.outcome = adopted ? Outcome.ADOPTED : Outcome.REJECTED;

        // proposer
        if (adopted) _resolve(postId, p.author, p.stake, 0, rewardProposer, 0);
        else _slash(postId, p.author, p.stake);

        // endorsers
        uint256[] storage ids = _postEndorsements[postId];
        for (uint256 i = 0; i < ids.length; i++) {
            Endorsement storage e = endorsements[ids[i]];
            if (e.fcc != FCCStatus.PASSED) {
                _resolve(postId, e.endorser, e.stake, 0, 0, 0);            // unverified: refund only
            } else if (adopted) {
                _resolve(postId, e.endorser, e.stake, 0, rewardEndorser, 0);
            } else if (e.isSupport || exemptionRevoked[ids[i]]) {
                _slash(postId, e.endorser, e.stake);                        // advocated the rejected position
            } else {
                _resolve(postId, e.endorser, e.stake, 0, 0, 0);            // opposed beforehand: deposit exempt
            }
            if (!adopted && !e.isSupport && awardedPoints[ids[i]] > 0 && badge.isMember(e.endorser)) {
                uint256 pts = awardedPoints[ids[i]];                        // no zero-risk hedge: dP_RE clawed back
                awardedPoints[ids[i]] = 0;
                badge.addPoints(e.endorser, -int256(pts), "opposing RE on a rejected proposal: dP_RE clawed back");
                emit PointsClawedBack(ids[i], e.endorser, pts);
            }
        }
        emit Settled(postId, caseId, p.outcome);
    }

    /// @notice Non-referral sunset (Section V-D): a proposal that never reached theta_PR within T_TTL expires.
    ///         The proposer and FCC-passed supporting endorsers lose lambda_idle of their deposits; others are refunded.
    function expire(uint256 postId) external {
        Post storage p = posts[postId];
        require(p.exists && !p.referred, "ProposalBoard: not expirable");
        require(p.outcome == Outcome.OPEN, "ProposalBoard: already closed");
        require(block.timestamp >= p.createdAt + postExpiry, "ProposalBoard: not yet expired");
        p.outcome = Outcome.EXPIRED;
        uint256 burnP = (p.stake * idleBurnBps) / 10000;
        _resolve(postId, p.author, p.stake - burnP, burnP, 0, 0);
        uint256[] storage ids = _postEndorsements[postId];
        for (uint256 i = 0; i < ids.length; i++) {
            Endorsement storage e = endorsements[ids[i]];
            uint256 burnE = (e.fcc == FCCStatus.PASSED && e.isSupport) ? (e.stake * idleBurnBps) / 10000 : 0;
            _resolve(postId, e.endorser, e.stake - burnE, burnE, 0, 0);
        }
        emit Settled(postId, 0, Outcome.EXPIRED);
    }

    function _slash(uint256 postId, address member, uint256 amount) internal {
        uint256 n = _recordRejection(member);
        uint256 burnAmt = (amount * burnRateBps(n)) / 10000;
        _resolve(postId, member, amount - burnAmt, burnAmt, 0, n);
    }

    function _resolve(uint256 postId, address member, uint256 refund, uint256 burnAmt, uint256 reward, uint256 n) internal {
        if (burnAmt > 0) rdao.burn(burnAmt);
        if (refund > 0) require(rdao.transfer(member, refund), "ProposalBoard: refund failed");
        if (reward > 0) rdao.mint(member, reward);
        emit StakeResolved(postId, member, refund, burnAmt, reward, n);
    }

    /// @dev Appends a rejection and returns n = rejections inside the trailing window (including this one).
    function _recordRejection(address member) internal returns (uint256 n) {
        uint64[] storage r = _rejections[member];
        r.push(uint64(block.timestamp));
        uint256 cutoff = block.timestamp > rejectionWindow ? block.timestamp - rejectionWindow : 0;
        for (uint256 i = r.length; i > 0; i--) {
            if (r[i - 1] <= cutoff) break;
            n++;
        }
    }

    function _pull(address from, uint256 amount) internal {
        if (amount > 0) require(rdao.transferFrom(from, address(this), amount), "ProposalBoard: stake transfer failed");
    }

    function _popcount(uint8 x) internal pure returns (uint8 c) {
        while (x != 0) {
            c += x & 1;
            x >>= 1;
        }
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    /// @notice lambda(n) in basis points; n = 0 returns 0.
    function burnRateBps(uint256 n) public view returns (uint256) {
        if (n == 0) return 0;
        uint256 len = burnScheduleBps.length;
        return burnScheduleBps[n < len ? n - 1 : len - 1];
    }

    function rejectionsInWindow(address member) external view returns (uint256 n) {
        uint64[] storage r = _rejections[member];
        uint256 cutoff = block.timestamp > rejectionWindow ? block.timestamp - rejectionWindow : 0;
        for (uint256 i = r.length; i > 0; i--) {
            if (r[i - 1] <= cutoff) break;
            n++;
        }
    }

    function endorsementsOf(uint256 postId) external view returns (uint256[] memory) {
        return _postEndorsements[postId];
    }

    function burnSchedule() external view returns (uint16[] memory) {
        return burnScheduleBps;
    }

    function isReferred(uint256 postId) external view returns (bool) {
        return posts[postId].referred;
    }

    function authorOf(uint256 postId) external view returns (address) {
        return posts[postId].author;
    }

    // ---------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------

    /// @notice Sets lambda(n). Must be non-decreasing and end at 100% so a finite N* exists (Appendix A).
    function setBurnSchedule(uint16[] calldata scheduleBps) external onlyAdmin {
        require(scheduleBps.length > 0, "empty schedule");
        for (uint256 i = 0; i < scheduleBps.length; i++) {
            require(scheduleBps[i] <= 10000, "max 100%");
            if (i > 0) require(scheduleBps[i] >= scheduleBps[i - 1], "schedule must be non-decreasing");
        }
        require(scheduleBps[scheduleBps.length - 1] == 10000, "schedule must reach 100%");
        delete burnScheduleBps;
        for (uint256 i = 0; i < scheduleBps.length; i++) burnScheduleBps.push(scheduleBps[i]);
    }

    function setPeerReview(address pr) external onlyAdmin { peerReview = IPeerReviewOutcome(pr); }
    function setFccAgent(address agent, bool enabled) external onlyAdmin { isFccAgent[agent] = enabled; }
    function setTauFCC(uint8 v) external onlyAdmin { require(v > 0 && v <= FCC_ITEMS, "invalid tau"); tauFCC = v; }
    function setPreVerificationPoints(uint256 proposer, uint256 endorser) external onlyAdmin {
        pointsProposer = proposer;
        pointsEndorser = endorser;
    }
    function setReferralParams(uint256 thetaMin_, uint256 rhoBps_) external onlyAdmin {
        require(thetaMin_ > 0 && rhoBps_ <= 10000, "invalid params");
        thetaMin = thetaMin_;
        rhoBps = rhoBps_;
    }
    function setStakes(uint256 proposer, uint256 endorser) external onlyAdmin {
        stakeProposer = proposer;
        stakeEndorser = endorser;
    }
    function setRewards(uint256 proposer, uint256 endorser) external onlyAdmin {
        rewardProposer = proposer;
        rewardEndorser = endorser;
    }
    function setRejectionWindow(uint64 v) external onlyAdmin { require(v > 0, "invalid window"); rejectionWindow = v; }
    function setPostExpiry(uint64 v) external onlyAdmin { postExpiry = v; }
    function setIdleBurnBps(uint256 v) external onlyAdmin { require(v <= 10000, "max 100%"); idleBurnBps = v; }
    function setSettleDelay(uint64 v) external onlyAdmin { settleDelay = v; }
    function setMaxEndorsementsPerPost(uint256 v) external onlyAdmin { require(v > 0, "invalid cap"); maxEndorsementsPerPost = v; }
    function setMinPostTier(uint8 tier) external onlyAdmin { minPostTier = tier; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
}
