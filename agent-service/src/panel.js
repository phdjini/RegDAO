/**
 * Reviewer selection for H2 (manuscript Section V-E).
 *
 * Reviewers are drawn at random from the qualified pool, not taken in rank order, because the
 * hypergeometric bound of Section V-E assumes random assignment. When the domain-relevant pool is
 * smaller than N_min, the panel is stratified: part of it is drawn at random from domain experts and
 * the rest from Council+ members outside the domain, so a cartel inside one narrow specialty cannot
 * fill the panel.
 */
const crypto = require("crypto");

function comb(n, k) {
  if (k < 0 || k > n) return 0;
  k = Math.min(k, n - k);
  let r = 1;
  for (let i = 1; i <= k; i++) r = (r * (n - k + i)) / i;
  return r;
}

/** Seats a biased minority needs to block approval under the two-thirds rule. */
function blockSeats(theta) {
  return theta - Math.ceil((2 * theta) / 3) + 1;
}

/** P(X >= k) for X ~ Hypergeometric(N, b, theta). */
function tailProb(N, b, theta, k) {
  let s = 0;
  for (let x = k; x <= Math.min(b, theta); x++) s += comb(b, x) * comb(N - b, theta - x);
  return s / comb(N, theta);
}

/** Smallest N with blocking probability <= eps; 0 when the minority can never reach k_B seats. */
function nMin(b, theta, eps) {
  const k = blockSeats(theta);
  if (k > b) return 0;
  let N = Math.max(theta, b);
  while (tailProb(N, b, theta, k) > eps) N += 1;
  return N;
}

function sample(arr, k, rand = crypto.randomInt) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = rand(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, Math.max(0, k));
}

/**
 * @param {object[]} ranked   qualified (Gold+) candidates, most domain-relevant first
 * @param {(c:object)=>boolean} isCouncil  true for Council+ candidates
 * @param {{theta:number, b:number, eps:number, spare:number, rand?:Function}} opts
 * @returns {{mode:'random'|'stratified', nMin:number, domainPool:number, invite:object[]}}
 */
function selectReviewers(ranked, isCouncil, { theta, b, eps, spare = 2, rand }) {
  const domainSize = Math.min(ranked.length, Math.max(theta + spare, Math.ceil(ranked.length / 2)));
  const domain = ranked.slice(0, domainSize);
  const cross = ranked.slice(domainSize).filter(isCouncil);
  const need = nMin(b, theta, eps);

  if (domain.length >= need || cross.length === 0) {
    return { mode: "random", nMin: need, domainPool: domain.length, invite: sample(domain, theta + spare, rand) };
  }
  const kCross = Math.min(cross.length, Math.floor(theta / 2) + 1);
  const kDomain = theta + spare - kCross;
  return {
    mode: "stratified",
    nMin: need,
    domainPool: domain.length,
    invite: [...sample(domain, kDomain, rand), ...sample(cross, kCross, rand)],
  };
}

module.exports = { blockSeats, tailProb, nMin, sample, selectReviewers };
