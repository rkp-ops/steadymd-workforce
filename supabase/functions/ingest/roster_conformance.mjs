import { buildRoster, pdt, isoDate, credOf, ACTIVE_THRESHOLD } from "./core.mjs";
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

console.log("ACTIVE_THRESHOLD (node):", ACTIVE_THRESHOLD);

// ---- fixtures (quoted fields on purpose: names carry commas) ----
const F = {
  roster: `Name,NPI,Email,Credential,Licensed States
"Alice Adams, MD",1000000001,alice@x.com,MD,"TX, CA"
"Bob Baker, FNP",1000000002,bob@x.com,FNP,
"Eve East",1000000003,,,NY
`,
  license: `First Name,Last Name,Npi,Email,Title,License State,License Number
Alice,Adams,1000000001,alice@x.com,MD,TX,L1
Alice,Adams,1000000001,alice@x.com,MD,CA,L2
`,
  consult: `Clinician GUID,Clinician Display Name,Clinician Email,Partner Name,Program Name,Consult Type,Consult GUID,Consult Status Created At,Consult Status ID,Consult Created At
guid-eve-000001,"Eve East, NP",eve@x.com,Amazon Clinic,Prog,async_messaging,cons-1,"June 2, 2026, 10:00 AM",completed,"June 2, 2026, 9:00 AM"
`,
  sli: `Clinician,Partner,Program Name,Consult Type,Consult GUID,State,SLI Completed,SLI Received
"Dan Nurse, NP",Amazon Clinic,Prog,async_messaging,cons-2,TX,2026-06-10 10:00:00,2026-06-10 09:00:00
"Alice Adams, MD",Amazon Clinic,Prog,async_messaging,cons-3,TX,2026-06-11 10:00:00,2026-06-11 09:00:00
`,
  incentive: `Clinician Full Name,Clinician Email,Partner Name,Program Name,Consult Type,States,Amount,Launched Time,License Type,Incentive Name,Budget Name
"Alice Adams, MD",alice@x.com,Amazon Clinic,Prog,async_messaging,TX,50.00,2026-06-12 10:00:00,MD,Inc,Bud
`,
  shift: `Name,User,Hours,Shift Type,Entity Name,Start Time,End Time
Bob Baker,bob@x.com,8,Regular,CSL,06/01/2026 09:00 AM,06/01/2026 05:00 PM
`,
};

// ---- minimal RFC4180 CSV parser for the harness ----
function parseCsv(text) {
  const rows = []; let i = 0, field = "", row = [], inQ = false;
  const t = text.replace(/\r\n/g, "\n").replace(/^﻿/, "");
  while (i < t.length) {
    const c = t[i];
    if (inQ) {
      if (c === '"') { if (t[i + 1] === '"') { field += '"'; i += 2; continue; } inQ = false; i++; continue; }
      field += c; i++; continue;
    }
    if (c === '"') { inQ = true; i++; continue; }
    if (c === ",") { row.push(field); field = ""; i++; continue; }
    if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; i++; continue; }
    field += c; i++;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  const hdr = rows.shift();
  return rows.filter(r => r.length && !(r.length === 1 && r[0] === "")).map(r => Object.fromEntries(hdr.map((h, j) => [h, r[j] ?? ""])));
}

// build the Node buildRoster inputs the way index.ts does
function nodeInputs() {
  const roster = parseCsv(F.roster), license = parseCsv(F.license), sli = parseCsv(F.sli), incentive = parseCsv(F.incentive), shift = parseCsv(F.shift);
  const consultTuples = [], consultAct = new Map(); const seen = new Set();
  for (const r of parseCsv(F.consult)) {
    const g = (r["Clinician GUID"] || "").trim(); const d = pdt(r["Consult Status Created At"]); const dd = isoDate(d);
    if (g && g.length >= 8) {
      if (!seen.has(g)) { seen.add(g); consultTuples.push({ name: (r["Clinician Display Name"] || "").trim() || null, email: (r["Clinician Email"] || "").trim() || null, guid: g }); }
      let a = consultAct.get(g); if (!a) { a = { name: (r["Clinician Display Name"] || "").trim() || null, email: (r["Clinician Email"] || "").trim() || null, partners: new Set(), programs: new Set(), modalities: new Set(), consults: new Set(), last: null }; consultAct.set(g, a); }
      if (r["Partner Name"]) a.partners.add(r["Partner Name"]); if (r["Program Name"]) a.programs.add(r["Program Name"]);
      if (r["Consult Type"]) a.modalities.add(r["Consult Type"]); if (r["Consult GUID"]) a.consults.add(r["Consult GUID"]);
      if (dd && (a.last === null || dd > a.last)) a.last = dd;
    }
  }
  return { roster, license, sli, incentive, shift, consultTuples, consultAct };
}

// ---- python golden ----
function pythonGolden(confirmed, overrides) {
  const dir = mkdtempSync(join(tmpdir(), "rc-"));
  const paths = {};
  for (const [k, v] of Object.entries(F)) { const p = join(dir, k + ".csv"); writeFileSync(p, v); paths[k] = p; }
  const py = `
import sys, json
sys.path.insert(0, "../../../platform/ingest")
from datetime import date, timedelta
from identity_lib import build_roster
found = {"roster": ${JSON.stringify(paths.roster)}, "license": ${JSON.stringify(paths.license)},
         "consult": ${JSON.stringify(paths.consult)}, "sli": ${JSON.stringify(paths.sli)},
         "incentive": ${JSON.stringify(paths.incentive)}, "shift": ${JSON.stringify(paths.shift)}}
rows, _ = build_roster(found, date(2026,7,7), timedelta(days=90),
                       frozenset(${JSON.stringify([...confirmed])}), ${JSON.stringify(overrides)})
print(json.dumps(rows))
`;
  const out = execFileSync("python3", ["-c", py], { encoding: "utf8" });
  return JSON.parse(out);
}

function normalize(rows) {
  return rows.map(r => ({ ...r,
    needs: [...(r.needs || [])].sort(), emails: [...(r.emails || [])].sort(), aliases: [...(r.aliases || [])].sort(),
    license_states: [...(r.license_states || [])].sort(), active_states: [...(r.active_states || [])].sort(),
    programs: [...(r.programs || [])].sort(), partners: [...(r.partners || [])].sort(), modalities: [...(r.modalities || [])].sort(),
  })).sort((a, b) => String(a.name).localeCompare(String(b.name)) || String(a.npi).localeCompare(String(b.npi)));
}

function diff(label, confirmed, overrides) {
  const inp = nodeInputs();
  const node = normalize(buildRoster(inp, confirmed, overrides).rows);
  const py = normalize(pythonGolden(confirmed, overrides));
  const a = JSON.stringify(node, null, 1), b = JSON.stringify(py, null, 1);
  if (a === b) { console.log(`\n✅ ${label}: MATCH (${node.length} clinicians)`); node.forEach(r => console.log(`   ${r.name} · ${r.credential||'—'} · ${r.tier||'—'} · ${r.status} · states[${r.license_states}] · consults ${r.consult_count} · $${r.incentive_usd} · ${r.shift_hours}h`)); return true; }
  console.log(`\n❌ ${label}: MISMATCH`);
  const nl = node, pl = py;
  const max = Math.max(nl.length, pl.length);
  for (let i = 0; i < max; i++) {
    const A = JSON.stringify(nl[i]), B = JSON.stringify(pl[i]);
    if (A !== B) { console.log(`  row ${i} NODE: ${A}`); console.log(`  row ${i} PY  : ${B}`); }
  }
  return false;
}

let ok = true;
ok = diff("case1: no confirmed/overrides", new Set(), {}) && ok;
ok = diff("case2: confirm Dan + override Bob->MD/TX", new Set(["dan nurse"]), { "baker bob": { credential: "MD", states: ["TX"] } }) && ok;
console.log(ok ? "\n=== ALL CONFORMANCE CHECKS PASSED ===" : "\n=== CONFORMANCE FAILED ===");
process.exit(ok ? 0 : 1);
