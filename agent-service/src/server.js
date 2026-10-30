require("dotenv").config();
const express = require("express");
const cron = require("node-cron");
const { ethers } = require("ethers");

const { verifyToken } = require("./email");
const { peerReview } = require("./chain");
const scanNewCases = require("./scanNewCases");
const scheduler = require("./scheduler");
const processFCC = require("./processFCC");
const assignJoinReviewers = require("./assignJoinReviewers");

const app = express();
app.use(express.json());

// ---------------------------------------------------------------
// 이메일 수락/거절 버튼 클릭 처리
// ---------------------------------------------------------------
app.get("/invite/respond", async (req, res) => {
  try {
    const { token } = req.query;
    const payload = verifyToken(token);
    const { caseId, inviteIndex, action, role } = payload;

    const dashboard = process.env.DASHBOARD_URL || "대시보드";
    if (action === "accept") {
      // 수락은 예치금(S_PPR) 스테이킹이 필요하므로 본인 지갑으로 직접 서명해야 한다.
      const how = role === "editor" ? "PeerReview.acceptEditorship" : "PeerReview.acceptInvite";
      return res.send(renderPage(
        "지갑으로 수락을 완료해 주세요",
        `수락하려면 ${dashboard}에서 지갑을 연결한 뒤 ${how}(${caseId}${role === "editor" ? "" : ", " + inviteIndex})를 호출해 예치금을 걸어야 합니다. 예치금은 리뷰를 마치면 판정 방향과 무관하게 전액 반환되고 RDAO 보상이 지급됩니다.`
      ));
    }

    if (role === "editor" || inviteIndex < 0) {
      return res.send(renderPage("확인되었습니다", "에디터 거절 의사가 전달되었습니다. 에이전트가 다음 스캔에서 다른 에디터를 배정합니다."));
    }

    const tx = await peerReview.declineInvite(caseId, inviteIndex);
    await tx.wait();
    res.send(renderPage("거절 처리 완료", "리뷰어 초대를 거절하셨습니다. 참여해주셔서 감사합니다."));
  } catch (e) {
    console.error(e);
    res.status(400).send(renderPage("처리 실패", "이미 응답했거나 유효하지 않은 링크입니다. " + (e.message || "")));
  }
});

function renderPage(title, message) {
  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><title>${title}</title>
    <style>body{font-family:sans-serif;max-width:480px;margin:80px auto;padding:24px;text-align:center;color:#1E2A42;}
    h1{font-size:20px;} p{color:#565F78;font-size:14px;line-height:1.6;}</style></head>
    <body><h1>${title}</h1><p>${message}</p></body></html>`;
}

// ---------------------------------------------------------------
// 정성적 성과 주장 접수 (예: 세미나 연사 초빙, 언론 기고 등)
// 본인 지갑 서명으로 신원을 증명해 제출한다 (별도 로그인 불필요).
// ---------------------------------------------------------------
app.post("/claims/achievement", async (req, res) => {
  try {
    const { address, description, signature } = req.body;
    if (!address || !description || !signature) {
      return res.status(400).json({ error: "address, description, signature가 모두 필요합니다." });
    }
    const message = `RegDAO 성과 주장 제출: ${description}`;
    const recovered = ethers.verifyMessage(message, signature);
    if (recovered.toLowerCase() !== address.toLowerCase()) {
      return res.status(401).json({ error: "서명이 유효하지 않습니다." });
    }

    const tx = await peerReview.initiateCase(1 /* ACHIEVEMENT */, 0, address, description);
    const receipt = await tx.wait();
    const caseId = Number(await peerReview.caseCount());

    res.json({ ok: true, caseId, message: "성과 주장이 접수되었습니다. 곧 에디터가 배정됩니다." });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message || "처리 중 오류가 발생했습니다." });
  }
});

app.get("/health", (req, res) => res.json({ ok: true, time: new Date().toISOString() }));

// ---------------------------------------------------------------
// 주기 실행: 매시 정각에 신규 안건 스캔 + 시간초과 에스컬레이션
// (외부 cron으로 `npm run scan` / `npm run escalate`를 직접 돌려도 무방합니다)
// ---------------------------------------------------------------
cron.schedule("0 * * * *", async () => {
  console.log("[cron] 정기 스캔 시작", new Date().toISOString());
  try { await processFCC.main(); } catch (e) { console.error("[cron] FCC 오류:", e); }
  try { await scanNewCases.main(); } catch (e) { console.error("[cron] scan 오류:", e); }
  try { await scheduler.main(); } catch (e) { console.error("[cron] escalate 오류:", e); }
  try { await assignJoinReviewers.main(); } catch (e) { console.error("[cron] join 배정 오류:", e); }
});

const PORT = process.env.SERVER_PORT || 3001;
app.listen(PORT, () => {
  console.log(`RegDAO 피어리뷰 에이전트 서비스 실행 중: http://localhost:${PORT}`);
  console.log("매시 정각에 자동으로 신규 안건 스캔 및 시간초과 재배정을 수행합니다.");
});
