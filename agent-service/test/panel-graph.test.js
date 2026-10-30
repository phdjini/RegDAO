// Unit tests for reviewer selection (H2) and the interaction-graph exemption check. Run: npm test
const test = require("node:test");
const assert = require("node:assert");
const { nMin, blockSeats, selectReviewers } = require("../src/panel");
const { assess } = require("../src/graph");

test("N_min matches Table 9 of the manuscript (b = 3)", () => {
  assert.deepStrictEqual([3, 5, 6, 7].map((t) => nMin(3, t, 0.01)), [43, 77, 24, 29]);
  assert.deepStrictEqual([3, 5, 6, 7].map((t) => nMin(3, t, 0.05)), [20, 35, 15, 18]);
  assert.strictEqual(nMin(3, 9, 0.01), 0); // k_B = 4 > b
  assert.deepStrictEqual([2, 3, 5, 9].map(blockSeats), [1, 2, 2, 4]);
});

const people = (n, tier, tag) => Array.from({ length: n }, (_, i) => ({ address: `0x${tag}${i}`, tier }));
let seed = 1;
const rand = (k) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % k; };

test("draws at random from the domain pool when it is at least N_min", () => {
  const ranked = [...people(90, 3, "d"), ...people(10, 4, "c")];
  const r = selectReviewers(ranked, (c) => c.tier >= 4, { theta: 3, b: 3, eps: 0.05, spare: 2, rand });
  assert.strictEqual(r.mode, "random");
  assert.strictEqual(r.invite.length, 5);
  assert.ok(r.invite.every((c) => ranked.indexOf(c) < r.domainPool));
});

test("stratifies with cross-domain Council members when the domain pool is below N_min", () => {
  const ranked = [...people(8, 3, "d"), ...people(8, 4, "c")];
  const r = selectReviewers(ranked, (c) => c.tier >= 4, { theta: 3, b: 3, eps: 0.01, spare: 2, rand });
  assert.strictEqual(r.mode, "stratified");
  assert.strictEqual(r.invite.length, 5);
  const cross = r.invite.filter((c) => ranked.indexOf(c) >= r.domainPool);
  assert.strictEqual(cross.length, 2);
  assert.ok(cross.every((c) => c.tier >= 4));
});

test("flags an opposer tied to the proposer directly or through shared neighbours", () => {
  const P = "0xP", O = "0xO";
  const direct = [1, 2, 3].map(() => ({ a: O, b: P }));
  assert.strictEqual(assess(direct, O, P).flag, true);
  const shared = ["0xA", "0xB", "0xC", "0xD"].flatMap((x) => [{ a: x, b: P }, { a: O, b: x }]);
  const r = assess(shared, O, P);
  assert.strictEqual(r.flag, true);
  assert.strictEqual(r.jaccard, 1);
  const apart = [{ a: O, b: "0xA" }, { a: P, b: "0xB" }];
  assert.strictEqual(assess(apart, O, P).flag, false);
});
