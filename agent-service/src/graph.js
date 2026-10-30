/**
 * Interaction-graph check for the opposition exemption (manuscript Section IV-D1).
 *
 * Every FCC-passed RE is an undirected edge between its author and the proposal's author. An opposing
 * endorser loses the slashing exemption when, outside the proposal under review, it is tied to the
 * proposer either directly (edge weight >= minWeight) or through a shared neighbourhood
 * (Jaccard overlap of their neighbour sets >= minOverlap, over at least minUnion neighbours).
 * Both are evidence that the "opposition" may be a hedge placed by the proposer's own circle.
 */

function buildGraph(edges) {
  const weight = new Map(); // "a|b" -> count
  const nbrs = new Map();   // a -> Set(b)
  const key = (a, b) => (a < b ? `${a}|${b}` : `${b}|${a}`);
  for (const { a, b } of edges) {
    const x = a.toLowerCase(), y = b.toLowerCase();
    if (x === y) continue;
    weight.set(key(x, y), (weight.get(key(x, y)) || 0) + 1);
    if (!nbrs.has(x)) nbrs.set(x, new Set());
    if (!nbrs.has(y)) nbrs.set(y, new Set());
    nbrs.get(x).add(y);
    nbrs.get(y).add(x);
  }
  return {
    weight: (a, b) => weight.get(key(a.toLowerCase(), b.toLowerCase())) || 0,
    neighbours: (a) => nbrs.get(a.toLowerCase()) || new Set(),
  };
}

function overlap(g, a, b) {
  const A = new Set(g.neighbours(a)), B = new Set(g.neighbours(b));
  A.delete(b.toLowerCase());
  B.delete(a.toLowerCase());
  let inter = 0;
  for (const x of A) if (B.has(x)) inter += 1;
  const union = A.size + B.size - inter;
  return { jaccard: union === 0 ? 0 : inter / union, union };
}

/**
 * @param {{a:string,b:string}[]} edges  interactions excluding the proposal under review
 * @returns {{flag:boolean, weight:number, jaccard:number, union:number}}
 */
function assess(edges, endorser, proposer, { minWeight = 3, minOverlap = 0.5, minUnion = 4 } = {}) {
  const g = buildGraph(edges);
  const w = g.weight(endorser, proposer);
  const { jaccard, union } = overlap(g, endorser, proposer);
  return { flag: w >= minWeight || (union >= minUnion && jaccard >= minOverlap), weight: w, jaccard, union };
}

module.exports = { buildGraph, overlap, assess };
