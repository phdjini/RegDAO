require("dotenv").config();
const nodemailer = require("nodemailer");
const crypto = require("crypto");

const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: Number(process.env.SMTP_PORT || 587),
  secure: false,
  auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
});

/**
 * 초대 링크에 서명한다. 링크만으로 위조 없이 caseId/inviteIndex/role/action을
 * 검증할 수 있도록 HMAC 서명을 붙인다 (별도 로그인 없이 원클릭 수락/거절 지원).
 */
function signToken(payload) {
  const json = JSON.stringify(payload);
  const b64 = Buffer.from(json).toString("base64url");
  const sig = crypto.createHmac("sha256", process.env.INVITE_TOKEN_SECRET).update(b64).digest("hex");
  return `${b64}.${sig}`;
}

function verifyToken(token) {
  const [b64, sig] = String(token).split(".");
  if (!b64 || !sig) throw new Error("invalid token format");
  const expected = crypto.createHmac("sha256", process.env.INVITE_TOKEN_SECRET).update(b64).digest("hex");
  if (expected !== sig) throw new Error("invalid token signature");
  return JSON.parse(Buffer.from(b64, "base64url").toString("utf8"));
}

async function sendReviewerInviteEmail({ to, caseId, inviteIndex, caseTitle, role }) {
  const acceptToken = signToken({ caseId, inviteIndex, action: "accept", role });
  const declineToken = signToken({ caseId, inviteIndex, action: "decline", role });
  const base = process.env.PUBLIC_BASE_URL;

  const acceptUrl = `${base}/invite/respond?token=${acceptToken}`;
  const declineUrl = `${base}/invite/respond?token=${declineToken}`;
  const roleLabel = role === "editor" ? "에디터" : "리뷰어";

  await transporter.sendMail({
    from: process.env.MAIL_FROM,
    to,
    subject: `[RegDAO] "${caseTitle}" 안건 ${roleLabel} 위촉 요청`,
    html: `
      <div style="font-family:sans-serif;max-width:520px;margin:0 auto;padding:24px;border:1px solid #ddd;">
        <h2 style="margin-top:0;">RegDAO ${roleLabel} 위촉 요청</h2>
        <p>아래 안건에 대한 <b>${roleLabel}</b>로 위촉되었습니다. ${process.env.INVITE_TIMEOUT_HOURS || 48}시간 내에 수락 여부를 회신해주세요.</p>
        <p style="background:#f5f2e9;padding:12px;border-radius:4px;"><b>${caseTitle}</b></p>
        <div style="margin-top:24px;">
          <a href="${acceptUrl}" style="display:inline-block;background:#3E6350;color:#fff;padding:12px 24px;border-radius:4px;text-decoration:none;margin-right:10px;">수락합니다</a>
          <a href="${declineUrl}" style="display:inline-block;background:#A63D2F;color:#fff;padding:12px 24px;border-radius:4px;text-decoration:none;">거절합니다</a>
        </div>
        <p style="color:#888;font-size:12px;margin-top:24px;">본 메일은 RegDAO 피어리뷰 AI 에이전트가 자동 발송했습니다. 기한 내 응답이 없으면 다른 회원에게 자동으로 재배정됩니다.</p>
      </div>
    `,
  });
}

async function sendJoinReviewerAssignedEmail({ to, applicationId, applicantOrg }) {
  const base = process.env.PUBLIC_DASHBOARD_URL || "";
  await transporter.sendMail({
    from: process.env.MAIL_FROM,
    to,
    subject: `[RegDAO] 가입 신청 #${applicationId} 심사 담당자로 배정되었습니다`,
    html: `
      <div style="font-family:sans-serif;max-width:520px;margin:0 auto;padding:24px;border:1px solid #ddd;">
        <h2 style="margin-top:0;">가입 신청 심사 배정 안내</h2>
        <p>창립 등급(Council/Elder) 회원 중 무작위로 귀하가 아래 가입 신청의 심사 담당자로 배정되었습니다.</p>
        <p style="background:#f5f2e9;padding:12px;border-radius:4px;"><b>신청 #${applicationId}</b> · 소속: ${applicantOrg}</p>
        <p>대시보드의 "신청 현황" 탭에서 지갑 연결 후 승인/반려를 처리해주세요.${base ? ` <a href="${base}">${base}</a>` : ""}</p>
        <p style="color:#888;font-size:12px;margin-top:24px;">본 메일은 RegDAO 가입심사 AI 에이전트가 자동 발송했습니다.</p>
      </div>
    `,
  });
}

module.exports = { sendReviewerInviteEmail, sendJoinReviewerAssignedEmail, signToken, verifyToken };
