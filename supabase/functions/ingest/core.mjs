// ============================================================================
// core.mjs — pure ingestion logic shared by the Edge Function (Deno) and the
// Node conformance harness. NO Deno/Node-specific imports live here, so the ONE
// algorithm runs in both places. index.ts imports these; test/roster_conformance
// runs them under Node and diffs against the Python identity_lib.build_roster.
//
// Faithful port of platform/ingest/identity_lib.py + the pure helpers of
// ingest.py (date parsing, modality, detection).
// ============================================================================

export const REF = { y: 2026, mo: 7, d: 7 };
export const ACTIVE_DAYS = 90;
export const DISCONTINUED = ["astellas", "rezilient", "medzip"];

export const norm = (h) => (h || "").toLowerCase().replace(/[^a-z0-9]/g, "");
export const s = (v) => { const t = ((v ?? "") + "").trim(); return t || null; };
const MONTHS = { january:1,february:2,march:3,april:4,may:5,june:6,july:7,august:8,september:9,october:10,november:11,december:12 };

export function pdt(v) {
  const str = ((v ?? "") + "").trim();
  if (!str) return null;
  let m;
  if ((m = str.match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/)))
    return { y:+m[1], mo:+m[2], d:+m[3], h:+(m[4]||0), mi:+(m[5]||0), s:+(m[6]||0) };
  if ((m = str.match(/^([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4}),\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP]M)$/i))) {
    const mo = MONTHS[m[1].toLowerCase()]; if (!mo) return null;
    let h = +m[4] % 12; if (m[7].toUpperCase() === "PM") h += 12;
    return { y:+m[3], mo, d:+m[2], h, mi:+m[5], s:+(m[6]||0) };
  }
  if ((m = str.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s+(\d{1,2}):(\d{2})\s*([AP]M))?$/i))) {
    let h = +(m[4]||0); if (m[6]) { h = h % 12; if (m[6].toUpperCase() === "PM") h += 12; }
    return { y:+m[3], mo:+m[1], d:+m[2], h, mi:+(m[5]||0), s:0 };
  }
  return null;
}
const pad = (n) => String(n).padStart(2, "0");
export const isoDT = (d) => d ? `${d.y}-${pad(d.mo)}-${pad(d.d)}T${pad(d.h)}:${pad(d.mi)}:${pad(d.s)}` : null;
export const isoDate = (d) => d ? `${d.y}-${pad(d.mo)}-${pad(d.d)}` : null;
export const epoch = (d) => Date.UTC(d.y, d.mo - 1, d.d, d.h, d.mi, d.s) / 1000;
function minusDays(r, days) { const dt = new Date(Date.UTC(r.y, r.mo - 1, r.d) - days * 86400000);
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth()+1)}-${pad(dt.getUTCDate())}`; }
export const ACTIVE_THRESHOLD = minusDays(REF, ACTIVE_DAYS);
export const isDiscontinued = (partner) => { const p = norm((partner ?? "") + ""); return DISCONTINUED.some(d => p.includes(d)); };

export const SIGNATURES = {
  shift: ["entityname", "hours", "shifttype"], license: ["licensestate", "licensenumber"],
  incentive: ["incentivename", "amount", "budgetname"], roster: ["credential", "licensedstates"],
  sli: ["slireceived", "sliduetime", "slistatus"], consult: ["consultstatusid", "consultstatuscreatedat"],
};
export function detect(headers) {
  const hs = headers.map(norm); let best = null, bestScore = 0;
  for (const [typ, sig] of Object.entries(SIGNATURES)) {
    const score = sig.reduce((n, c) => n + (hs.some(h => c === h || h.includes(c)) ? 1 : 0), 0);
    if (score >= sig.length - (sig.length === 2 ? 0 : 1) && score > bestScore) { best = typ; bestScore = score; }
  }
  return best;
}

export const LAB_TYPES = new Set(["lab-order", "async_lab_order", "async_lab_result"]);
export const WORKED = new Set(["completed", "rejected", "referred_out", "in_call"]);
export function modality(ctype, hasInCall) {
  if (ctype && LAB_TYPES.has(ctype)) return "lab";
  if ((ctype || "").startsWith("critical_values_phone_call")) return "sync_phone";
  if (hasInCall) return "sync_video";
  if (ctype === "async_messaging" || ctype === "chart_review") return "messaging";
  return "other";
}
export const addSetV = (set, v) => { const t = ((v ?? "") + ""); if (t) set.add(t); };

// -------------------------------------------------------------- roster engine
const RCREDS = new Set(["md","do","np","pa","fnp","rn","dnp","phd","aprn","crnp","pmhnp","agnp","whnp",
  "msn","apn","bc","ii","iii","jr","sr","faap","facp","lcsw","psyd","arnp","ma","cma","rma","lpn","cnp","anp","acnp","agacnp","agpcnp","apnp","ms","gc"]);
const CRED_RE = /\b(MD|DO|PA|FNP|PMHNP|AGACNP|AGPCNP|AGNP|WHNP|ACNP|APRN|ARNP|CRNP|DNP|CNP|ANP|APNP|APN|NP|CMA|RMA|MA|LPN|RN|MSN|MS|GC|PSYD|PHD|LCSW)\b/gi;
const SEAT = new Set(["MD", "DO", "PA"]);
function tierOf(cred) {
  if (!cred) return null;
  const c = cred.toUpperCase().replace(/[-.]/g, "");
  if (SEAT.has(c) || c.includes("NP") || c.includes("APRN") || c.includes("ARNP") || c.includes("CRNP") || c.includes("DNP") || c === "APN" || c === "APNP") return "seat";
  return "support";
}
function toks(name) {
  const x = (name || "").toLowerCase().replace(/[,.\-/|()]/g, " ");
  return [...new Set(x.split(/\s+/).filter(t => t && !RCREDS.has(t) && t.length > 1))];
}
const nkey = (name) => { const t = toks(name); return t.length ? t.sort().join(" ") : ""; };
function credOf(name) {
  if (!name) return "";
  const tail = name.includes(",") ? name.slice(name.lastIndexOf(",") + 1) : name;
  const m = (tail.match(CRED_RE) || name.match(CRED_RE));
  return m && m.length ? m[m.length - 1].toUpperCase() : "";
}
export { credOf };

export function buildRoster(files, confirmed = new Set(), overrides = {}) {
  const par = new Map();
  const find = (x) => { if (!par.has(x)) par.set(x, x); let r = x; while (par.get(r) !== r) r = par.get(r);
    while (par.get(x) !== r) { const nx = par.get(x); par.set(x, r); x = nx; } return r; };
  const union = (a, b) => { par.set(find(a), find(b)); };
  const strongKeys = (npi, email, guid) => { const ks = [];
    if (npi && /^\d+$/.test((npi + "").trim())) ks.push("npi:" + (npi + "").trim());
    if (email && (email + "").includes("@")) ks.push("email:" + (email + "").trim().toLowerCase());
    if (guid && (guid + "").trim().length >= 8) ks.push("guid:" + (guid + "").trim());
    return ks; };
  const tuples = [];
  const addTuple = (name, npi, email, guid, cred, src) => {
    const ks = strongKeys(npi, email, guid);
    for (let i = 0; i < ks.length - 1; i++) union(ks[i], ks[i + 1]);
    tuples.push({ name, npi, email, guid, cred, src, ks });
  };
  for (const r of files.roster || []) addTuple(r["Name"], r["NPI"], r["Email"], null, r["Credential"], "roster");
  if (files.license) { const seen = new Set();
    for (const r of files.license) { const key = `${r["Npi"]}|${(r["Email"]||"").toLowerCase()}|${r["First Name"]}|${r["Last Name"]}`;
      if (seen.has(key)) continue; seen.add(key);
      addTuple(`${r["First Name"]||""} ${r["Last Name"]||""}`.trim(), r["Npi"], r["Email"], null, r["Title"], "license"); } }
  for (const c of files.consultTuples || []) addTuple(c.name, null, c.email, c.guid, credOf(c.name), "metabase");
  if (files.incentive) { const seen = new Set();
    for (const r of files.incentive) { const k = `${r["Clinician Email"]}|${r["Clinician Full Name"]}`;
      if (seen.has(k)) continue; seen.add(k);
      addTuple(r["Clinician Full Name"], null, r["Clinician Email"], null, r["License Type"], "incentive"); } }
  if (files.shift) { const seen = new Set();
    for (const r of files.shift) { const k = `${r["User"]}|${r["Name"]}`;
      if (seen.has(k)) continue; seen.add(k);
      addTuple(r["Name"], null, r["User"], null, null, "shift"); } }

  const entNpi = new Map(), entNk = new Map();
  const getset = (m, k) => { let x = m.get(k); if (!x) { x = new Set(); m.set(k, x); } return x; };
  for (const t of tuples) { if (!t.ks.length) continue; const e = find(t.ks[0]);
    if (t.npi && /^\d+$/.test((t.npi + "").trim())) getset(entNpi, e).add((t.npi + "").trim());
    const k = nkey(t.name); if (t.name && k) getset(entNk, e).add(k); }
  const byName = new Map();
  for (const [e, nks] of entNk) for (const k of nks) getset(byName, k).add(find(e));
  for (const [, entsSet] of byName) {
    const ents = [...new Set([...entsSet].map(find))]; if (ents.length < 2) continue;
    const npis = new Set(); for (const e of ents) for (const n of (entNpi.get(e) || [])) npis.add(n);
    if (npis.size <= 1) for (let i = 1; i < ents.length; i++) if (find(ents[0]) !== find(ents[i])) union(ents[0], ents[i]);
  }
  const name2ent = new Map();
  for (const t of tuples) { const k = nkey(t.name); if (t.ks.length && t.name && k) getset(name2ent, k).add(find(t.ks[0])); }
  const entityOf = (name, ks) => {
    if (ks.length) return find(ks[0]);
    const k = nkey(name); const ents = new Set([...(name2ent.get(k) || [])].map(find));
    if (ents.size === 1) return [...ents][0];
    if (ents.size > 1) return "AMBIG:" + k;
    return "NAMEONLY:" + k;
  };
  const E = new Map();
  const ent = (k) => { let e = E.get(k); if (!e) { e = { names:new Set(),creds:new Set(),npis:new Set(),emails:new Set(),guids:new Set(),lic:new Set(),act:new Set(),partners:new Set(),programs:new Set(),modalities:new Set(),consults:new Set(),shiftHours:0,incentive:0,last:null,sources:new Set() }; E.set(k, e); } return e; };
  const bumpLast = (e, last) => { if (last && (e.last === null || last > e.last)) e.last = last; };
  for (const t of tuples) {
    const e = ent(entityOf(t.name, t.ks));
    if (t.name && (t.name + "").trim()) e.names.add((t.name + "").trim());
    if (t.cred && (t.cred + "").trim()) e.creds.add((t.cred + "").trim().toUpperCase());
    if (t.npi && /^\d+$/.test((t.npi + "").trim())) e.npis.add((t.npi + "").trim());
    if (t.email && (t.email + "").includes("@")) e.emails.add((t.email + "").trim().toLowerCase());
    if (t.guid && (t.guid + "").length >= 8) e.guids.add((t.guid + "").trim());
    e.sources.add(t.src);
  }
  const actEnt = (name, npi, email, guid) => entityOf(name ?? null, strongKeys(npi, email, guid));
  if (files.consultAct) for (const [guid, a] of files.consultAct) {
    const e = ent(actEnt(a.name, null, a.email, guid));
    bumpLast(e, a.last); for (const p of a.partners) e.partners.add(p); for (const p of a.programs) e.programs.add(p);
    for (const m of a.modalities) e.modalities.add(m); for (const c of a.consults) e.consults.add(c);
  }
  for (const r of files.sli || []) {
    const e = ent(actEnt(r["Clinician"])); const d = pdt(r["SLI Completed"]) || pdt(r["SLI Received"]); const dd = isoDate(d); const st = (r["State"]||"").trim();
    if (r["Clinician"] && r["Clinician"].trim()) e.names.add(r["Clinician"].trim());
    bumpLast(e, dd); addSetV(e.partners, r["Partner"]); addSetV(e.programs, r["Program Name"]); addSetV(e.modalities, r["Consult Type"]); addSetV(e.consults, r["Consult GUID"]);
    if (st && dd && dd >= ACTIVE_THRESHOLD) e.act.add(st);
  }
  for (const r of files.incentive || []) {
    const e = ent(actEnt(r["Clinician Full Name"], null, r["Clinician Email"])); const d = pdt(r["Launched Time"]); const dd = isoDate(d); const st = (r["States"]||"").trim();
    const amt = parseFloat(r["Amount"] || "0") || 0;
    bumpLast(e, dd); addSetV(e.partners, r["Partner Name"]); addSetV(e.programs, r["Program Name"]); addSetV(e.modalities, r["Consult Type"]); e.incentive += amt;
    if (st && dd && dd >= ACTIVE_THRESHOLD) e.act.add(st);
  }
  for (const r of files.shift || []) {
    const e = ent(actEnt(r["Name"], null, r["User"])); const d = pdt(r["End Time"]); const hrs = parseFloat(r["Hours"] || "0") || 0;
    bumpLast(e, isoDate(d)); e.shiftHours += hrs;
  }
  for (const r of files.license || []) {
    const e = ent(actEnt(`${r["First Name"]||""} ${r["Last Name"]||""}`.trim(), r["Npi"], r["Email"])); const st = (r["License State"]||"").trim();
    if (st) e.lic.add(st);
  }
  for (const r of files.roster || []) {
    const e = ent(actEnt(r["Name"], r["NPI"], r["Email"]));
    for (let st of (r["Licensed States"]||"").split(",")) { st = st.trim(); if (st) e.lic.add(st); }
  }

  const isActive = (e) => e.last !== null && e.last >= ACTIVE_THRESHOLD;
  const bestName = (e) => e.names.size ? [...e.names].reduce((a, b) => b.length > a.length ? b : a) : "(unknown)";
  const oneCred = (e) => { const cs = [...e.creds].filter(Boolean); return cs.length ? cs.reduce((a, b) => b.length > a.length ? b : a) : null; };
  const NONPERSON = new Set(["assigned not", "assigned unassigned", "na", "test"]);
  const rows = []; const credByEmail = new Map();
  for (const [k, e] of E) {
    const strong = k.startsWith("npi:") || k.startsWith("email:") || k.startsWith("guid:");
    const nameonly = k.startsWith("NAMEONLY:");
    if (!(strong || nameonly)) continue;
    const onRoster = e.sources.has("roster") || e.sources.has("license");
    const kname = nameonly ? k.slice("NAMEONLY:".length) : "";
    if (nameonly) { if (NONPERSON.has(kname)) continue; if (!onRoster && e.last === null) continue; }
    const nm = bestName(e);
    const nk = nameonly ? kname : nkey(nm);
    let cred = oneCred(e); let states = [...e.lic].sort();
    const ov = overrides[nk];
    if (ov) { if (ov.removed) continue; if (ov.credential) cred = ov.credential; if (ov.states != null) states = [...new Set(ov.states)].sort(); }
    const conf = confirmed.has(nk);
    for (const em of e.emails) if (em && cred && !credByEmail.has(em)) credByEmail.set(em, cred);
    const tier = tierOf(cred);
    const needs = [];
    if (!cred) needs.push("credential");
    if (tier === "seat" && !states.length) needs.push("state");
    const addq = nameonly && !onRoster && !conf && e.last !== null;
    let status;
    if (addq) status = "ADD-TO-ROSTER";
    else if (needs.length) status = "NEEDS-CORRECTION";
    else if (conf || isActive(e)) status = "active";
    else status = "inactive";
    rows.push({
      name: nm, credential: cred, tier, needs,
      npi: [...e.npis].sort()[0] ?? null,
      emails: [...e.emails].sort(), aliases: [...e.names].filter(Boolean).sort(),
      license_states: states, active_states: [...e.act].sort(),
      programs: [...e.programs].filter(Boolean).sort(), partners: [...e.partners].filter(Boolean).sort(),
      modalities: [...e.modalities].filter(Boolean).sort(),
      consult_count: e.consults.size, shift_hours: Math.round(e.shiftHours * 10) / 10,
      incentive_usd: Math.round(e.incentive * 100) / 100,
      last_active: e.last, status,
    });
  }
  rows.sort((a, b) => String(a.name).localeCompare(String(b.name)) || String(a.npi).localeCompare(String(b.npi)));
  return { rows, credByEmail };
}
