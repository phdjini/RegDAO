/** Interaction edges for the graph checks: every FCC-passed RE links its author to the proposal's author. */
async function loadInteractionEdges(board, excludePostId = 0) {
  const count = Number(await board.endorsementCount());
  const authors = new Map();
  const edges = [];
  for (let id = 1; id <= count; id++) {
    const e = await board.endorsements(id);
    if (!e.exists || Number(e.fcc) !== 1 || Number(e.postId) === Number(excludePostId)) continue;
    const pid = Number(e.postId);
    if (!authors.has(pid)) authors.set(pid, (await board.posts(pid)).author);
    edges.push({ a: e.endorser, b: authors.get(pid) });
  }
  return edges;
}
module.exports = { loadInteractionEdges };
