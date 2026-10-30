require("dotenv").config();
const { ethers } = require("ethers");

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const agentWallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);

const BADGE_ABI = [
  "function isMember(address) view returns (bool)",
  "function tierOf(address) view returns (uint8)",
  "function ownerOfBadge(uint256) view returns (address)",
  "function pointsOf(address) view returns (uint256)",
];

const BOARD_ABI = [
  "function postCount() view returns (uint256)",
  "function posts(uint256) view returns (uint256 id, address author, uint8 category, string title, string content, string attachmentURI, uint64 createdAt, uint256 supportCount, uint256 opposeCount, uint256 verifiedCount, uint256 stake, bool proposerAwarded, bool referred, uint8 outcome, bool exists)",
  "function endorsementCount() view returns (uint256)",
  "function endorsements(uint256) view returns (uint256 id, uint256 postId, address endorser, bool isSupport, string reason, uint8 fcc, uint8 fccMask, bool appealed, uint256 stake, uint64 createdAt, bool exists)",
  "function recordFCC(uint256 endorsementId, uint8 mask)",
  "function settle(uint256 postId, uint256 caseId)",
];

const PROFILE_ABI = [
  "function profiledMemberCount() view returns (uint256)",
  "function profiledMembers(uint256) view returns (address)",
  "function getProfile(address) view returns (string bio, string[] interests, string email, string phone, bool exists)",
  "function eligibleApproverCount(uint8) view returns (uint256)",
];

const JOIN_ABI = [
  "function applicationCount() view returns (uint256)",
  "function applications(uint256) view returns (address applicant, string reason, string org, uint64 submittedAt, address assignedReviewer, uint64 assignedAt, bool approved, bool rejected)",
  "function minApproverTier() view returns (uint8)",
  "function assignReviewer(uint256,address)",
];

const PEER_REVIEW_ABI = [
  "function caseCount() view returns (uint256)",
  "function cases(uint256) view returns (uint256 id, uint8 caseType, uint256 sourcePostId, address claimant, string description, address chiefEditor, address coEditor, uint8 status, uint64 createdAt, uint64 publishedAt, uint256 approveCount, bool adopted, string finalTitle, string finalDocumentURI, string finalSummary)",
  "function reviewersOf(uint256, uint256) view returns (address reviewer, uint8 status, uint64 invitedAt, uint64 respondedAt, bool reviewSubmitted, bool approve, string reviewURI, uint256 stake)",
  "function caseOfPost(uint256) view returns (uint256)",
  "function editorState(uint256) view returns (bool chiefAccepted, bool coAccepted, uint256 chiefStake, uint256 coStake, uint64 reviewDeadline)",
  "function reviewersCount(uint256) view returns (uint256)",
  "function acceptedReviewerCount(uint256) view returns (uint256)",
  "function reviewerQuorum() view returns (uint256)",
  "function initiateCase(uint8,uint256,address,string) returns (uint256)",
  "function assignEditors(uint256,address,address)",
  "function inviteReviewer(uint256,address) returns (uint256)",
  "function declineInvite(uint256,uint256)",
  "function markNoShow(uint256,uint256)",
  "function markInviteTimedOut(uint256,uint256)",
  "event CaseInitiated(uint256 indexed id, uint8 caseType, uint256 sourcePostId, address indexed claimant)",
];

const badge = new ethers.Contract(process.env.BADGE_ADDRESS, BADGE_ABI, agentWallet);
const board = new ethers.Contract(process.env.PROPOSAL_BOARD_ADDRESS, BOARD_ABI, agentWallet);
const profile = new ethers.Contract(process.env.MEMBER_PROFILE_ADDRESS, PROFILE_ABI, agentWallet);
const peerReview = new ethers.Contract(process.env.PEER_REVIEW_ADDRESS, PEER_REVIEW_ABI, agentWallet);
const joinRegistry = new ethers.Contract(process.env.JOIN_REGISTRY_ADDRESS, JOIN_ABI, agentWallet);

module.exports = { provider, agentWallet, badge, board, profile, peerReview, joinRegistry };
