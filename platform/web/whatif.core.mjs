// ============================================================================
// whatif.core.mjs — the pure modeling + honesty substrate for the What-If engine.
//
// THE ONE PRINCIPLE, ENFORCED IN CODE: every counterfactual this module produces
// is an Estimate — a value carrying a confidence band AND the named method that
// produced it. `est()` is the only constructor for a modeled number and it refuses
// to build one without a method string. There is no code path to a bare modeled
// number. This is the spec's core rule ("build the honesty in at the data layer,
// not as a disclaimer footer") made structural rather than aspirational.
//
// Pure: no DOM, no fetch, no Deno/Node APIs. The browser console inlines this file
// (build_live.py strips the export lines) and the Node harness imports it, so the
// ONE modeling algorithm is tested, never reimplemented — the same discipline that
// keeps the ingest roster engine honest.
//
// Two framing corrections from the spec are baked into the shapes here, not left to
// the UI:
//   1. Participation, not licensure, is the coverage lever (modelState takes a
//      target participation fraction; peer fits are over participation).
//   2. Local lift and volume-weighted aggregate contribution are computed together,
//      never one without the other (aggregateContribution returns both).
// ============================================================================

const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

// ---- Estimate: the unit of every modeled number ------------------------------
// { value, lo, hi, method, inputs, modeled }. Band is [lo,hi] in the value's units
// (a fraction for SLA). `method` is a human-readable sentence the UI shows on hover.
function est(value, lo, hi, method, inputs) {
  if (!method || typeof method !== "string") throw new Error("est(): a modeled number needs a named method");
  return { value, lo: Math.min(lo, hi), hi: Math.max(lo, hi), method, inputs: inputs || null, modeled: true };
}
// A measured fact wears the same shape (zero-width band, modeled:false) so the UI
// renders facts and estimates uniformly and never dresses a fact up as a guess.
function fact(value, basis) {
  return { value, lo: value, hi: value, method: basis || "observed", inputs: null, modeled: false };
}
// An SLA-fraction estimate: same as est() but clamps value and band into [0,1] —
// a modeled SLA can never claim >100% attainment. (est() itself stays unclamped so
// it can carry signed aggregate deltas.)
function estFrac(value, lo, hi, method, inputs) {
  return est(clamp(value, 0, 1), clamp(lo, 0, 1), clamp(hi, 0, 1), method, inputs);
}

const attain = (met, decided) => (decided > 0 ? met / decided : null); // fraction or null

// ---- Wilson score interval: an honest band on an observed rate -----------------
// Small-volume states (IN at 68 SLIs) MUST read as more uncertain than TN (886).
// Wilson is the standard, honest small-sample interval — it stays inside [0,1] and
// widens correctly at the extremes where p±k/√n lies.
function wilson(met, decided, z = 1.96) {
  if (!decided) return null;
  const p = met / decided, n = decided, z2 = z * z;
  const d = 1 + z2 / n, c = p + z2 / (2 * n);
  const h = z * Math.sqrt((p * (1 - p) + z2 / (4 * n)) / n);
  return { lo: clamp((c - h) / d, 0, 1), hi: clamp((c + h) / d, 0, 1) };
}

// An observed state/modality SLA, as a fact with an honest Wilson band.
function observedSla(met, decided) {
  const p = attain(met, decided);
  if (p === null) return null;
  const w = wilson(met, decided);
  return { value: p, lo: w.lo, hi: w.hi, method: `observed · ${met}/${decided} met · Wilson 95%`, inputs: { met, decided }, modeled: false };
}

// ---- volume-weighted aggregation --------------------------------------------
// rows: [{met, decided}]. The aggregate SLA is volume-weighted (the spec's second
// framing correction: a 30-visit state barely moves it), returned with a Wilson band.
function volWeightedSla(rows) {
  let m = 0, d = 0;
  for (const r of rows) { m += (r.met || 0); d += (r.decided || 0); }
  if (d <= 0) return null;
  const w = wilson(m, d);
  return { value: m / d, met: m, decided: d, lo: w.lo, hi: w.hi };
}

// ---- weighted least squares (for the participation-scaled fit) ---------------
// points: [{x, y, w}] → line y = intercept + slope·x, plus a weighted residual std
// that becomes the band. Degenerate inputs collapse to the weighted mean (slope 0).
function wlsFit(points) {
  let sw = 0, swx = 0, swy = 0, swxx = 0, swxy = 0;
  for (const { x, y, w } of points) { sw += w; swx += w * x; swy += w * y; swxx += w * x * x; swxy += w * x * y; }
  if (sw <= 0) return { slope: 0, intercept: 0, predict: () => 0, resid: 0 };
  const denom = sw * swxx - swx * swx;
  if (Math.abs(denom) < 1e-12) { const mean = swy / sw; return { slope: 0, intercept: mean, predict: () => mean, resid: 0 }; }
  const slope = (sw * swxy - swx * swy) / denom, intercept = (swy - slope * swx) / sw;
  let sse = 0; for (const { x, y, w } of points) { const e = y - (intercept + slope * x); sse += w * e * e; }
  return { slope, intercept, predict: (x) => intercept + slope * x, resid: Math.sqrt(sse / sw) };
}

// ---- the three imputation methods (the spec's dropdown) ----------------------
// Each takes the covered peer states (already filtered by the caller to those with
// a stable-enough SLA) for one modality, plus the target participation, and returns
// an Estimate. Peers: [{st, participation, met, decided}].

// (a) peer-state average: inherit the volume-weighted SLA of covered peers.
function peerAverage(peers) {
  const vw = volWeightedSla(peers);
  if (!vw) return null;
  const slas = peers.filter(p => p.decided > 0).map(p => p.met / p.decided);
  const lo = Math.min(...slas), hi = Math.max(...slas);
  return estFrac(vw.value, lo, hi,
    `peer-state avg · volume-weighted SLA of ${peers.length} covered states (same modality); band = peer spread`,
    { peers: peers.length, decided: vw.decided });
}

// (b) participation-scaled (DEFAULT): fit SLA ~ participation across covered states
// and read it at the target. More honest than (a): bringing a high-demand state to a
// low participation will NOT reach the covered-state average, and extrapolating past
// the observed participation range widens the band (we say so in the method text).
function participationScaled(peers, targetPart) {
  const pts = peers.filter(p => p.decided > 0).map(p => ({ x: p.participation, y: p.met / p.decided, w: p.decided }));
  if (pts.length < 2) return null; // too thin to fit — caller falls back to peerAverage
  const fit = wlsFit(pts);
  const ceiling = Math.max(...pts.map(p => p.y));
  const xs = pts.map(p => p.x), xmax = Math.max(...xs);
  const val = clamp(Math.min(fit.predict(targetPart), ceiling), 0, 1); // never beat the best observed peer
  // band: fit residual, widened when extrapolating beyond the observed participation range
  const extrap = targetPart > xmax ? (targetPart - xmax) : 0;
  const band = Math.max(fit.resid + 0.6 * extrap, 0.02);
  return estFrac(val, val - band, val + band,
    `participation-scaled · WLS fit SLA~participation on ${pts.length} covered states, read at ${Math.round(targetPart * 100)}%` +
    (extrap > 0 ? ` (extrapolated beyond the ${Math.round(xmax * 100)}% top of the observed range — band widened)` : ""),
    { n: pts.length, slope: +fit.slope.toFixed(3), resid: +fit.resid.toFixed(3), extrapolated: extrap > 0 });
}

// (c) haircut: peer average minus a first-weeks ramp penalty for unfamiliarity.
function haircut(peers, penalty = 0.05) {
  const pa = peerAverage(peers);
  if (!pa) return null;
  const v = clamp(pa.value - penalty, 0, 1);
  const w = pa.hi - pa.value;
  return est(v, v - w - 0.01, v + w,
    `haircut · peer-state avg − ${Math.round(penalty * 100)}pp first-weeks ramp penalty`, pa.inputs);
}

// Dispatch + graceful fallback. method ∈ {'participation'|'peer'|'haircut'}.
function modelState(peers, targetPart, method) {
  let e = null;
  if (method === "peer") e = peerAverage(peers);
  else if (method === "haircut") e = haircut(peers);
  else e = participationScaled(peers, targetPart) || peerAverage(peers); // default, with fallback
  return e;
}

// ---- local lift vs volume-weighted aggregate contribution (both, always) -----
// The spec's non-negotiable: show local lift and weighted-aggregate contribution
// side by side. SLI volume is demand-driven, so a participation change moves the
// MET count (the SLA), not the decided count — decided_s is held constant.
function aggregateContribution(agg, stateBefore, newSlaEst) {
  const localBefore = attain(stateBefore.met, stateBefore.decided);
  const localAfter = newSlaEst.value;
  const localLift = localBefore == null ? localAfter : localAfter - localBefore;
  const aggBefore = agg.decided > 0 ? agg.met / agg.decided : null;
  const proj = (p) => (agg.decided > 0 ? (agg.met - stateBefore.met + p * stateBefore.decided) / agg.decided : null);
  const aggAfter = proj(localAfter);
  const d = (aggBefore == null || aggAfter == null) ? null : aggAfter - aggBefore;
  const dLo = aggBefore == null ? null : proj(newSlaEst.lo) - aggBefore;
  const dHi = aggBefore == null ? null : proj(newSlaEst.hi) - aggBefore;
  return {
    localBefore, localAfter, localLift,
    aggBefore, aggAfter, aggDelta: d, aggDeltaLo: dLo, aggDeltaHi: dHi,
    weight: agg.decided > 0 ? stateBefore.decided / agg.decided : 0, // this state's share of aggregate volume
  };
}

// Per clinician-hour efficiency of a coverage move (spec: "SLA bought per
// clinician-hour added"). Activations = licensed-but-not-participating we'd switch
// on; a rough hours proxy lets the client rank states by aggregate SLA per activation.
function aggDeltaPerActivation(aggDelta, activations) {
  return activations > 0 ? aggDelta / activations : null;
}

// ---- attribution waterfall (canonical order) ---------------------------------
// Levers interact, so order matters — the spec fixes coverage→productivity→hours→
// demand and requires it be stated. Each lever transforms a running state; we report
// each lever's MARGINAL delta on the metric in that fixed order. Family 1 uses one
// lever (coverage); families 2–8 append the rest without changing this primitive.
const CANONICAL_LEVER_ORDER = ["coverage", "productivity", "hours", "demand"];
function attributionWaterfall(baseState, levers, metricOf) {
  const ordered = [...levers].sort(
    (a, b) => CANONICAL_LEVER_ORDER.indexOf(a.kind) - CANONICAL_LEVER_ORDER.indexOf(b.kind));
  let cur = baseState, prev = metricOf(cur);
  const start = prev, steps = [];
  for (const lv of ordered) { cur = lv.apply(cur); const now = metricOf(cur); steps.push({ name: lv.name, kind: lv.kind, delta: now - prev }); prev = now; }
  return { start, end: prev, total: prev - start, order: CANONICAL_LEVER_ORDER, steps };
}

// ---- VPCH: never a free-floating fantasy slider ------------------------------
// The spec's coach's note: cap VPCH to what history has actually produced and show
// the band on the track. This clamps and flags when the ask exceeds history.
function clampVpch(target, histLo, histHi) {
  return { value: clamp(target, histLo, histHi), clamped: target < histLo || target > histHi, band: [histLo, histHi] };
}

// ---- backtest: if the model can't reproduce history, it can't predict --------
// Leave-one-out over the covered states: refit without each, predict its SLA from
// its own participation, compare to actual. Returns volume-weighted MAE + worst
// miss, so the UI can gate: a model outside tolerance is shown as a range, not a
// point (the spec's "no hidden logic, backtested" turned into a number).
function backtestParticipationFit(peers) {
  const pts = peers.filter(p => p.decided > 0).map(p => ({ x: p.participation, y: p.met / p.decided, w: p.decided }));
  if (pts.length < 3) return null;
  let sae = 0, sw = 0, worst = 0;
  for (let i = 0; i < pts.length; i++) {
    const train = pts.filter((_, j) => j !== i);
    const pred = clamp(wlsFit(train).predict(pts[i].x), 0, 1);
    const e = Math.abs(pred - pts[i].y);
    sae += pts[i].w * e; sw += pts[i].w; worst = Math.max(worst, e);
  }
  return { mae: sw > 0 ? sae / sw : null, worst, n: pts.length };
}

const WhatIf = {
  est, fact, attain, wilson, observedSla, volWeightedSla, wlsFit,
  peerAverage, participationScaled, haircut, modelState,
  aggregateContribution, aggDeltaPerActivation,
  attributionWaterfall, CANONICAL_LEVER_ORDER, clampVpch, backtestParticipationFit,
};
if (typeof window !== "undefined") window.WhatIf = WhatIf;

export { WhatIf };
export default WhatIf;
