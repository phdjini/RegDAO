/**
 * Scans pending reasoned endorsements, runs the FCC checklist and records the result on-chain.
 * Run periodically (server.js cron) or manually: `npm run fcc`.
 */
require("dotenv").config();
const Anthropic = require("@anthropic-ai/sdk");
const { board } = require("./chain");
const { evaluate } = require("./fcc");

const FCC_PENDING = 0;
const OUTCOME_OPEN = 0;

const client = process.env.ANTHROPIC_API_KEY ? new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY }) : null;
const MODEL = process.env.CLAUDE_MODEL || "claude-sonnet-4-6";

async function main() {
  console.log("=== FCC 점검 실행 ===", new Date().toISOString());
  const count = Number(await board.endorsementCount());
  const byAuthor = new Map(); // endorser -> [{id, reason}]
  const all = [];
  for (let id = 1; id <= count; id++) {
    const e = await board.endorsements(id);
    if (!e.exists) continue;
    all.push(e);
    const key = e.endorser.toLowerCase();
    if (!byAuthor.has(key)) byAuthor.set(key, []);
    byAuthor.get(key).push({ id: Number(e.id), reason: e.reason });
  }

  for (const e of all) {
    if (Number(e.fcc) !== FCC_PENDING) continue;
    const post = await board.posts(e.postId);
    if (Number(post.outcome) !== OUTCOME_OPEN) continue;

    const prior = byAuthor
      .get(e.endorser.toLowerCase())
      .filter((x) => x.id < Number(e.id))
      .map((x) => x.reason);
    const result = await evaluate(e.reason, { title: post.title, content: post.content }, prior, { client, model: MODEL });
    if (!result) {
      console.warn(`[RE ${e.id}] C4 분류기를 사용할 수 없어 보류합니다 (다음 실행에서 재시도).`);
      continue;
    }
    const tx = await board.recordFCC(e.id, result.mask);
    await tx.wait();
    const passed = result.items.filter(Boolean).length;
    console.log(`[RE ${e.id}] mask=0b${result.mask.toString(2).padStart(6, "0")} (${passed}/6) 기록 완료`);
  }
  console.log("=== FCC 점검 완료 ===");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { main };
