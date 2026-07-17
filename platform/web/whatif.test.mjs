// ============================================================================
// whatif.test.mjs — invariant harness for the What-If modeling core, run under
// Node against the REAL state cloud pulled from whatif_coverage() (decided>=20).
// It asserts the honesty properties the spec demands, not just that code runs:
//   * a modeled number cannot exist without a method (est throws)
//   * small-volume states carry wider bands than high-volume ones
//   * extrapolating participation beyond the observed range widens the band
//   * a low-volume state's aggregate contribution is tiny vs a high-volume one
//   * the attribution waterfall obeys the canonical lever order regardless of input
//   * the fit backtests (leave-one-out) within a stated tolerance
// Run: NODE_PATH=/opt/node22/lib/node_modules node platform/web/whatif.test.mjs
// ============================================================================
import { WhatIf as W } from "./whatif.core.mjs";

// Real rows: [state, licensed, participated, decided, met]  (from the live substrate)
const RAW = [
  ["FL",561,123,1123,1118],["NY",356,80,1051,1049],["CA",361,69,974,966],["TX",488,87,954,941],
  ["TN",221,22,886,880],["MD",226,45,580,350],["AZ",381,84,544,541],["KY",196,32,437,432],
  ["VA",297,53,436,434],["PA",265,50,420,416],["MI",237,40,398,391],["NC",202,40,382,377],
  ["WA",352,69,375,371],["IL",283,48,281,268],["OH",289,43,277,275],["NJ",242,36,235,230],
  ["LA",171,29,202,196],["MN",194,30,200,200],["MA",168,28,198,193],["CO",347,49,192,190],
  ["SC",141,13,47,42],["IN",162,13,68,58],
];
const STATES = RAW.map(([st, lic, part, decided, met]) => ({ st, lic, part, decided, met, participation: part / lic }));
const byId = Object.fromEntries(STATES.map(s => [s.st, s]));
const peersExcept = (st) => STATES.filter(s => s.st !== st && s.decided >= 20);
const agg = STATES.reduce((a, s) => ({ met: a.met + s.met, decided: a.decided + s.decided }), { met: 0, decided: 0 });

let pass = 0, fail = 0;
const ok = (name, cond, extra) => { if (cond) { pass++; console.log(`  ✓ ${name}`); } else { fail++; console.log(`  ✗ ${name}${extra ? "  — " + extra : ""}`); } };
const approx = (a, b, e = 1e-6) => Math.abs(a - b) <= e;

console.log("whatif.core — honesty invariants on the real state cloud\n");

// 1. A modeled number cannot exist without a method.
let threw = false; try { W.est(0.9, 0.8, 1.0); } catch { threw = true; }
ok("est() refuses a modeled number with no method", threw);
ok("fact() carries a zero-width band and modeled:false", (() => { const f = W.fact(0.5, "observed"); return f.lo === 0.5 && f.hi === 0.5 && f.modeled === false; })());

// 2. Small-volume states carry wider observed bands than high-volume ones.
const inSla = W.observedSla(byId.IN.met, byId.IN.decided);   // 58/68
const tnSla = W.observedSla(byId.TN.met, byId.TN.decided);   // 880/886
ok("IN (68 SLIs) has a wider Wilson band than TN (886)", (inSla.hi - inSla.lo) > (tnSla.hi - tnSla.lo),
  `IN=${(inSla.hi - inSla.lo).toFixed(3)} TN=${(tnSla.hi - tnSla.lo).toFixed(3)}`);
ok("observed SLA is a fact (modeled:false) with a real basis", inSla.modeled === false && /observed/.test(inSla.method));

// 3. participation-scaled: extrapolating beyond the observed range widens the band + is flagged.
const peersSC = peersExcept("SC");
const sc20 = W.participationScaled(peersSC, 0.20);
const sc40 = W.participationScaled(peersSC, 0.40);
ok("participation-scaled returns an Estimate with a named method", sc40 && /participation-scaled/.test(sc40.method));
ok("modeling SC at 40% is flagged as extrapolated (beyond observed participation)", sc40.inputs.extrapolated === true, sc40.method);
ok("extrapolated band (40%) is wider than in-range (20%)", (sc40.hi - sc40.lo) > (sc20.hi - sc20.lo),
  `40%=${(sc40.hi - sc40.lo).toFixed(3)} 20%=${(sc20.hi - sc20.lo).toFixed(3)}`);
ok("modeled SLA never exceeds the best observed peer (<=1.0) and stays in [0,1]", sc40.value <= 1 && sc40.lo >= 0 && sc40.hi <= 1);

// 4. Local lift vs aggregate contribution — volume-weighting must be visible.
const contribSC = W.aggregateContribution(agg, byId.SC, sc40);          // SC: 47 decided
const bigLift = W.est(0.99, 0.98, 1.0, "test");                          // same target SLA…
const contribTN = W.aggregateContribution(agg, byId.TN, bigLift);       // …applied to TN: 886 decided
ok("SC carries a smaller aggregate weight than TN", contribSC.weight < contribTN.weight,
  `SC=${contribSC.weight.toFixed(4)} TN=${contribTN.weight.toFixed(4)}`);
ok("lifting a 47-SLI state moves the aggregate <0.5pp (local≠aggregate)", Math.abs(contribSC.aggDelta) < 0.005,
  `aggΔ=${(contribSC.aggDelta * 100).toFixed(3)}pp, localLift=${(contribSC.localLift * 100).toFixed(1)}pp`);
ok("aggregate contribution reports BOTH local and aggregate (never one alone)",
  contribSC.localLift != null && contribSC.aggDelta != null && contribSC.aggDeltaLo != null && contribSC.aggDeltaHi != null);

// 5. Imputation dropdown: peer vs haircut vs default.
const pa = W.modelState(peersSC, 0.40, "peer");
const hc = W.modelState(peersSC, 0.40, "haircut");
const def = W.modelState(peersSC, 0.40);
ok("haircut sits below peer-average (ramp penalty applied)", hc.value < pa.value, `haircut=${hc.value.toFixed(3)} peer=${pa.value.toFixed(3)}`);
ok("default method is participation-scaled", /participation-scaled/.test(def.method));
ok("modelState falls back to peer-average when peers are too thin to fit", (() => {
  const one = W.modelState([{ st: "X", participation: 0.2, met: 90, decided: 100 }], 0.4);
  return one && /peer-state avg/.test(one.method);
})());

// 6. Backtest — leave-one-out over covered states, volume-weighted MAE within tolerance.
const bt = W.backtestParticipationFit(STATES.filter(s => s.decided >= 20));
ok("backtest returns MAE + worst over the covered states", bt && bt.n >= 3 && bt.mae != null,
  bt ? `mae=${(bt.mae * 100).toFixed(1)}pp worst=${(bt.worst * 100).toFixed(1)}pp n=${bt.n}` : "null");
ok("backtest MAE is within a sane tolerance (<15pp) on real data", bt && bt.mae < 0.15, bt ? `${(bt.mae * 100).toFixed(1)}pp` : "null");

// 7. Attribution waterfall obeys the canonical order regardless of input order.
const levers = [
  { name: "Wisp ramp", kind: "demand", apply: s => ({ v: s.v - 0.4 }) },
  { name: "Saturday hours", kind: "hours", apply: s => ({ v: s.v + 1.1 }) },
  { name: "SC+MS participation", kind: "coverage", apply: s => ({ v: s.v + 3.1 }) },
  { name: "VPCH +0.3", kind: "productivity", apply: s => ({ v: s.v + 2.0 }) },
];
const wf = W.attributionWaterfall({ v: 0 }, levers, s => s.v);
ok("waterfall reorders to coverage→productivity→hours→demand", wf.steps.map(s => s.kind).join(",") === "coverage,productivity,hours,demand", wf.steps.map(s => s.kind).join(","));
ok("waterfall total equals the sum of marginal steps", approx(wf.total, wf.steps.reduce((a, s) => a + s.delta, 0)));

// 8. VPCH is clamped to history and flags an over-reach.
const v1 = W.clampVpch(2.5, 1.0, 2.0), v2 = W.clampVpch(1.5, 1.0, 2.0);
ok("VPCH above the historical band is clamped + flagged", v1.value === 2.0 && v1.clamped === true);
ok("VPCH inside the historical band passes through unflagged", v2.value === 1.5 && v2.clamped === false);

console.log(`\n${fail === 0 ? "ALL PASSED" : "FAILURES"} — ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
