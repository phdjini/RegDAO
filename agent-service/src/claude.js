require("dotenv").config();
const Anthropic = require("@anthropic-ai/sdk");

const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const MODEL = process.env.CLAUDE_MODEL || "claude-sonnet-4-6";

/**
 * 안건(제목+내용)과 후보 프로필 목록을 Claude에게 주고,
 * 가장 적합한 순서로 정렬된 후보 주소 배열을 받는다.
 *
 * @param {{title:string, content:string}} caseInfo
 * @param {Array<{address:string, bio:string, interests:string[]}>} candidates
 * @param {number} excludeCount - 이미 선정된 인원 수(에디터 등)만큼 제외하고 요청할 때 참고용
 * @returns {Promise<string[]>} 적합도 순으로 정렬된 지갑 주소 배열
 */
async function rankCandidates(caseInfo, candidates) {
  if (candidates.length === 0) return [];

  const candidateList = candidates
    .map((c, i) => `${i}. 주소: ${c.address}\n   소개: ${c.bio || "(없음)"}\n   관심분야: ${(c.interests || []).join(", ") || "(없음)"}`)
    .join("\n\n");

  const prompt = `당신은 산업 규제개혁 협의체(RegDAO)의 정책제안 피어리뷰를 위한 매칭 에이전트입니다.
아래 안건과 가장 관련성이 높은 순서대로 후보자 인덱스를 정렬해주세요.

[안건 제목]
${caseInfo.title}

[안건 내용]
${caseInfo.content}

[후보자 목록]
${candidateList}

반드시 아래 JSON 형식으로만 답하세요. 다른 설명은 절대 포함하지 마세요.
{"ranked_indices": [정수, 정수, ...]}`;

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    messages: [{ role: "user", content: prompt }],
  });

  const text = response.content.map((b) => (b.type === "text" ? b.text : "")).join("");
  const cleaned = text.replace(/```json|```/g, "").trim();

  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (e) {
    console.error("Claude 응답 파싱 실패:", text);
    // 파싱 실패 시 원래 순서 그대로 반환 (안전한 폴백)
    return candidates.map((c) => c.address);
  }

  const indices = parsed.ranked_indices || [];
  const ranked = indices
    .filter((i) => Number.isInteger(i) && i >= 0 && i < candidates.length)
    .map((i) => candidates[i].address);

  // 혹시 누락된 후보가 있으면 뒤에 이어붙임 (안전장치)
  for (const c of candidates) {
    if (!ranked.includes(c.address)) ranked.push(c.address);
  }
  return ranked;
}

module.exports = { rankCandidates };
