/**
 * Formality compliance check (FCC) — manuscript Section IV-C, Table 6.
 *
 * Each checklist item returns true/false; the result is recorded on-chain as a 6-bit mask
 * (bit k-1 <=> C_k) via ProposalBoard.recordFCC. Only C4 uses an AI classifier; C1-C3, C5, C6
 * are deterministic so that their outcome can be re-derived by anyone auditing the record.
 * None of the checks looks at whether the RE supports or opposes the proposal.
 */
require("dotenv").config();

const MIN_CHARS = Number(process.env.FCC_MIN_CHARS || 50);
const MAX_SIMILARITY = Number(process.env.FCC_MAX_SIMILARITY || 0.8);

// C1 — complete sentence of at least MIN_CHARS characters (Unicode code points, not bytes).
function c1MinimumLength(reason) {
  const text = reason.trim();
  const longEnough = [...text].length >= MIN_CHARS;
  const endsAsSentence = /([.!?。]|[다요음함임됨])["')\]]?$/u.test(text);
  return longEnough && endsAsSentence;
}

// C2 — refers to a specific provision or content of the proposal.
const REFERENT_PATTERNS = [
  /제\s*\d+\s*조/u,
  /제\s*\d+\s*항/u,
  /\b(article|art\.|section|sec\.|clause|paragraph|para\.)\s*\d+/i,
  /§\s*\d+/u,
];
function tokens(text) {
  return new Set(
    (text.toLowerCase().match(/[\p{Script=Hangul}]{2,}|[a-z][a-z0-9-]{3,}/gu) || [])
  );
}
function c2SpecificReferent(reason, proposal) {
  if (REFERENT_PATTERNS.some((re) => re.test(reason))) return true;
  const proposalTokens = tokens(`${proposal.title} ${proposal.content}`);
  let shared = 0;
  for (const t of tokens(reason)) if (proposalTokens.has(t)) shared += 1;
  return shared >= 2;
}

// C3 — at least one verifiable piece of evidence: citation, link, case, figure, or explicit logical link.
const EVIDENCE_PATTERNS = [
  /https?:\/\/\S+/i,
  /\bdoi:\s*10\.\d{4,}/i,
  /\[\d+\]/,
  /\d+(\.\d+)?\s*(%|퍼센트|억|만|원|건|명|percent|bn|million|billion)/iu,
  /(판례|판결|사례|선례|가이드라인|고시|시행령|법률|case\b|precedent|guidance|regulation)/iu,
  /(왜냐하면|때문에|따라서|그러므로|그 결과|because|therefore|hence|as a result|consequently)/iu,
];
function c3Evidence(reason) {
  return EVIDENCE_PATTERNS.some((re) => re.test(reason));
}

// C5 — not a substantive repeat of the same author's earlier reasoning (character-trigram Jaccard).
function trigrams(text) {
  const s = text.toLowerCase().replace(/\s+/g, " ").trim();
  const out = new Set();
  for (let i = 0; i + 3 <= s.length; i++) out.add(s.slice(i, i + 3));
  return out;
}
function similarity(a, b) {
  const A = trigrams(a);
  const B = trigrams(b);
  if (A.size === 0 || B.size === 0) return 0;
  let inter = 0;
  for (const g of A) if (B.has(g)) inter += 1;
  return inter / (A.size + B.size - inter);
}
function c5NonRepetition(reason, priorReasons) {
  return priorReasons.every((p) => similarity(reason, p) < MAX_SIMILARITY);
}

// C6 — no personally identifiable information.
const PII_PATTERNS = [
  /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i,       // e-mail
  /\b01[016789][-\s.]?\d{3,4}[-\s.]?\d{4}\b/,      // Korean mobile number
  /\b0\d{1,2}[-\s.]\d{3,4}[-\s.]\d{4}\b/,          // landline
  /\b\d{6}[-\s]?[1-8]\d{6}\b/,                     // resident registration number
  /\b(?:\d{4}[-\s]?){3}\d{4}\b/,                   // card-like 16-digit number
];
function c6NoPII(reason) {
  return !PII_PATTERNS.some((re) => re.test(reason));
}

/**
 * C4 — confined to proposal content, no personal attack on the proposer.
 * Uses the Claude API. Returns true/false, or null when the classifier is unavailable
 * (the caller then leaves the RE pending instead of guessing).
 */
async function c4NoPersonalAttack(reason, client, model) {
  if (!client) return null;
  const prompt = `You are a narrow content classifier for a regulatory consultation platform.
Decide whether the following reasoning contains a personal attack, insult, or disparagement aimed at a person
(for example the proposal's author) rather than at the proposal's content. Strong criticism of the proposal itself
is NOT a personal attack.

<reasoning>
${reason}
</reasoning>

Answer with JSON only: {"personal_attack": true|false}`;
  try {
    const res = await client.messages.create({
      model,
      max_tokens: 50,
      messages: [{ role: "user", content: prompt }],
    });
    const text = res.content.map((b) => (b.type === "text" ? b.text : "")).join("");
    const parsed = JSON.parse(text.replace(/```json|```/g, "").trim());
    if (typeof parsed.personal_attack !== "boolean") return null;
    return !parsed.personal_attack;
  } catch (e) {
    console.error("[FCC] C4 classifier failed:", e.message || e);
    return null;
  }
}

/**
 * Evaluates C1..C6. Returns { mask, items } or null if C4 could not be decided.
 * @param {string} reason
 * @param {{title:string, content:string}} proposal
 * @param {string[]} priorReasons the same author's earlier REs
 * @param {{client?:object, model?:string}} opts
 */
async function evaluate(reason, proposal, priorReasons, opts = {}) {
  const c4 = await c4NoPersonalAttack(reason, opts.client, opts.model);
  if (c4 === null) return null;
  const items = [
    c1MinimumLength(reason),
    c2SpecificReferent(reason, proposal),
    c3Evidence(reason),
    c4,
    c5NonRepetition(reason, priorReasons),
    c6NoPII(reason),
  ];
  const mask = items.reduce((m, ok, k) => (ok ? m | (1 << k) : m), 0);
  return { mask, items };
}

module.exports = {
  evaluate,
  c1MinimumLength,
  c2SpecificReferent,
  c3Evidence,
  c4NoPersonalAttack,
  c5NonRepetition,
  c6NoPII,
  similarity,
};
