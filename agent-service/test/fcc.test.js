// Unit tests for the deterministic FCC items and the C4 wrapper. Run: node --test test/
const test = require("node:test");
const assert = require("node:assert");
const fcc = require("../src/fcc");

const proposal = {
  title: "가상자산사업자 신고 요건 완화",
  content: "특정금융정보법 시행령 제10조의11에 따른 실명확인 입출금 계정 요건을 단계적으로 완화하자는 제안입니다.",
};
const good =
  "제10조의11 실명확인 입출금 계정 요건은 신규 사업자의 진입을 사실상 막고 있습니다. 2024년 신고 수리 건수가 3건에 그쳤기 때문에 단계적 완화가 필요합니다.";

const fakeClient = (attack) => ({
  messages: { create: async () => ({ content: [{ type: "text", text: JSON.stringify({ personal_attack: attack }) }] }) },
});

test("a well-formed RE passes all six items", async () => {
  const r = await fcc.evaluate(good, proposal, [], { client: fakeClient(false), model: "x" });
  assert.deepStrictEqual(r.items, [true, true, true, true, true, true]);
  assert.strictEqual(r.mask, 0x3f);
});

test("C1 counts characters, not bytes, and requires a sentence ending", () => {
  assert.strictEqual(fcc.c1MinimumLength("좋은 제안입니다."), false);
  assert.strictEqual(fcc.c1MinimumLength(good), true);
  assert.strictEqual(fcc.c1MinimumLength(good.replace(/\.$/, " 그리고")), false);
});

test("C2 accepts a provision reference or shared content terms", () => {
  assert.strictEqual(fcc.c2SpecificReferent("Article 5 is too broad because it covers custody.", proposal), true);
  assert.strictEqual(fcc.c2SpecificReferent("그냥 마음에 들지 않습니다. 전반적으로 별로입니다.", proposal), false);
});

test("C3 requires evidence or an explicit logical link", () => {
  assert.strictEqual(fcc.c3Evidence("See https://www.fsc.go.kr/no010101/80309 for details."), true);
  assert.strictEqual(fcc.c3Evidence("저는 이 제안이 좋다고 생각합니다."), false);
});

test("C4 maps the classifier output and returns null when unavailable", async () => {
  assert.strictEqual(await fcc.c4NoPersonalAttack(good, fakeClient(true), "x"), false);
  assert.strictEqual(await fcc.c4NoPersonalAttack(good, fakeClient(false), "x"), true);
  assert.strictEqual(await fcc.c4NoPersonalAttack(good, null, "x"), null);
  assert.strictEqual(await fcc.evaluate(good, proposal, [], {}), null);
});

test("C5 rejects near-copies of the author's earlier reasoning", () => {
  assert.strictEqual(fcc.c5NonRepetition(good, [good + " "]), false);
  assert.strictEqual(fcc.c5NonRepetition(good, ["전혀 다른 근거를 들어 반대 의견을 제시한 이전 글입니다."]), true);
});

test("C6 flags e-mail addresses, phone numbers and resident numbers", () => {
  assert.strictEqual(fcc.c6NoPII("문의는 hong@example.com 으로 주세요."), false);
  assert.strictEqual(fcc.c6NoPII("연락처 010-1234-5678"), false);
  assert.strictEqual(fcc.c6NoPII("주민번호 900101-1234567"), false);
  assert.strictEqual(fcc.c6NoPII(good), true);
});
