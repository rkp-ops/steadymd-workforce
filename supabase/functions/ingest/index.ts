// ============================================================================
// supabase/functions/ingest — in-console data ingestion (admin-gated).
//
// Canonical runtime for the monthly refresh, so it happens from the console with
// no terminal: the browser uploads the raw exports to the private `imports`
// Storage bucket and invokes this function, which parses, transforms, loads
// (service role, server-side), and re-anchors the clinician spine — then returns
// a report. The service key never reaches the browser.
//
// The PURE logic (date parsing, detection, modality, and the union-find roster
// engine) lives in ./core.mjs, shared verbatim with the Node conformance harness
// that diffs it against the Python identity_lib.build_roster — so there is ONE
// verified algorithm, no divergence. This file is the Deno IO + handler layer.
//
// Modes:
//   { mode:'load'|'dry', paths:[...] }   — files staged in Storage (real use)
//   { mode:'roster-test', files:{...} }  — inline fixtures, returns roster only
//
// The consult file streams with an incremental rollup (no hold-all-touches), so
// the 500k-row export fits the isolate.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { parse, CsvParseStream } from "jsr:@std/csv@1";
import { s, pdt, isoDT, isoDate, epoch, isDiscontinued, detect, modality, WORKED, buildRoster, addSetV } from "./core.mjs";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const REST = URL_ + "/rest/v1";
const SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SVC_H = { apikey: SVC, Authorization: "Bearer " + SVC, "Content-Type": "application/json" };
// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

// ---------------------------------------------------------------- CSV IO
function parseCsv(text: string): Row[] { return parse(text.replace(/^\uFEFF/, ""), { skipFirstRow: true }) as Row[]; }

// A partner-specific SLI export (e.g. Wisp) omits the shared `Partner` column and
// labels its deadline "<Partner> Due Time (Nhrs to complete)" instead of the
// canonical `SLI Due Time`. Left as-is those rows attribute to no partner and
// never score (the generated `sla_met` needs a due). This decides, FROM THE HEADER
// ROW ALONE, how to recover both — the partner name is embedded in the column
// header itself, far more reliable than a filename guess; the filename's leading
// token is only a backstop. Header-based so the SLI load can stream (see
// loadSliStreaming) instead of buffering a whole file to inspect row[0]. Standard
// multi-partner exports (both canonical columns present) return null (no-op).
function sliNormalizer(hdrs: string[], filename: string): { partner: string | null; dueKey: string | null } | null {
  if (hdrs.includes("Partner") && hdrs.includes("SLI Due Time")) return null;
  let partner: string | null = null, dueKey: string | null = null;
  for (const h of hdrs) {
    const m = h.match(/^\s*(.+?)\s+due\s*time\b/i);
    if (m && !/^sli$/i.test(m[1].trim())) { partner = m[1].trim(); dueKey = h; break; }
  }
  const partnerFallback = hdrs.includes("Partner") ? null : (partner || (filename.split(/[_.\-]/)[0] || null));
  if (!partnerFallback && !dueKey) return null;
  return { partner: partnerFallback, dueKey };
}
async function objBody(path: string): Promise<ReadableStream<Uint8Array>> {
  const r = await fetch(`${URL_}/storage/v1/object/imports/${path}`, { headers: { apikey: SVC, Authorization: "Bearer " + SVC } });
  if (!r.ok) throw new Error(`storage ${path} -> HTTP ${r.status}`);
  let stream: ReadableStream<Uint8Array> = r.body!;
  if (path.endsWith(".gz")) stream = stream.pipeThrough(new DecompressionStream("gzip"));
  return stream;
}
async function downloadText(path: string): Promise<string> { return await new Response(await objBody(path)).text(); }
async function headersOfPath(path: string): Promise<string[]> {
  const reader = (await objBody(path)).pipeThrough(new TextDecoderStream()).getReader();
  let buf = "";
  while (!buf.includes("\n")) { const { value, done } = await reader.read(); if (done) break; buf += value; if (buf.length > 262144) break; }
  reader.cancel().catch(() => {});
  const nl = buf.indexOf("\n");
  return (parse(nl >= 0 ? buf.slice(0, nl) : buf) as string[][])[0] || [];
}
async function streamConsult(path: string, onRow: (r: Row) => void): Promise<void> {
  const rows = (await objBody(path)).pipeThrough(new TextDecoderStream()).pipeThrough(new CsvParseStream({ skipFirstRow: true }));
  for await (const row of rows) onRow(row as unknown as Row);
}

// ---------------------------------------------------------------- REST load
async function clearTable(table: string) {
  const r = await fetch(`${REST}/${table}?id=not.is.null`, { method: "DELETE", headers: { ...SVC_H, Prefer: "return=minimal" } });
  if (![200, 204].includes(r.status)) throw new Error(`clear ${table} -> HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
}
async function insertRows(table: string, rows: Row[], batch = 1000): Promise<number> {
  let ok = 0;
  for (let i = 0; i < rows.length; i += batch) {
    const chunk = rows.slice(i, i + batch);
    for (let a = 0; a < 4; a++) {
      const r = await fetch(`${REST}/${table}`, { method: "POST", headers: { ...SVC_H, Prefer: "return=minimal" }, body: JSON.stringify(chunk) });
      if ([200, 201, 204].includes(r.status)) { ok += chunk.length; break; }
      if ([502, 503, 504].includes(r.status) && a < 3) { await new Promise(res => setTimeout(res, 2000 * (a + 1))); continue; }
      throw new Error(`insert ${table} @${i} -> HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
    }
  }
  return ok;
}
async function sourceUpload(kind: string, filename: string, n: number): Promise<string> {
  const r = await fetch(`${REST}/source_upload`, { method: "POST", headers: { ...SVC_H, Prefer: "return=representation" }, body: JSON.stringify({ source_kind: kind, filename, row_count: n }) });
  if (![200, 201].includes(r.status)) throw new Error(`source_upload -> HTTP ${r.status}`);
  return (await r.json())[0].id;
}
// Streaming loaders create the source_upload before the final row count is known,
// then patch it once streaming completes. Best-effort: provenance metadata only.
async function patchSourceCount(id: string, n: number): Promise<void> {
  await fetch(`${REST}/source_upload?id=eq.${id}`, { method: "PATCH", headers: { ...SVC_H, Prefer: "return=minimal" }, body: JSON.stringify({ row_count: n }) }).catch(() => {});
}
async function relink(): Promise<unknown> {
  for (let a = 0; a < 4; a++) {
    const r = await fetch(`${REST}/rpc/relink_clinician_spine`, { method: "POST", headers: SVC_H, body: "{}" });
    if (r.status === 200) return await r.json();
    if ([502, 503, 504].includes(r.status) && a < 3) { await new Promise(res => setTimeout(res, 2000 * (a + 1))); continue; }
    throw new Error(`relink -> HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
  }
}
async function restGet(pathq: string): Promise<Row[] | null> {
  const r = await fetch(`${REST}/${pathq}`, { headers: SVC_H }); return r.ok ? await r.json() : null;
}
async function fetchDecisions() {
  const rows = (await restGet("roster_decision?select=name_key,decision,credential,states")) || [];
  const confirmed = new Set<string>(); const overrides: Record<string, Row> = {};
  for (const d of rows) { const nk = d["name_key"]; if (!nk) continue;
    if (d["decision"] === "confirmed") confirmed.add(nk);
    const ov: Row = {};
    if (d["decision"] === "dismissed") ov.removed = true;
    if (d["credential"]) ov.credential = d["credential"];
    if (d["states"] != null) ov.states = d["states"];
    if (Object.keys(ov).length) overrides[nk] = ov;
  }
  return { confirmed, overrides };
}
const VOL_MIN = 20, VOL_RATIO = 1.6;
async function volumeAlert(kind: string, counts: Map<string, number>, uploadId: string): Promise<string[]> {
  const flags: string[] = [];
  const prior = await restGet(`ingest_partner_snapshot?source_kind=eq.${kind}&order=created_at.desc&limit=5000`);
  if (prior && prior.length) {
    const latest = prior[0]["created_at"];
    const prev = new Map<string, number>();
    for (const r of prior) if (r["created_at"] === latest) prev.set(r["partner"], r["n"]);
    for (const p of [...new Set([...counts.keys(), ...prev.keys()])].sort()) {
      const a = prev.get(p) || 0, b = counts.get(p) || 0;
      if (a >= VOL_MIN && b === 0) flags.push(`DISAPPEARED · ${p} · ${a} → 0`);
      else if (b >= VOL_MIN && a === 0) flags.push(`NEW · ${p} · 0 → ${b}`);
      else if (a > 0 && b > 0 && Math.max(a, b) >= VOL_MIN && Math.max(a, b) / Math.min(a, b) >= VOL_RATIO)
        flags.push(`${((b - a) / a * 100).toFixed(0)}% · ${p} · ${a} → ${b}`);
    }
  }
  const snap = [...counts.entries()].map(([p, n]) => ({ source_kind: kind, partner: p, n, source_upload_id: uploadId }));
  if (snap.length) await insertRows("ingest_partner_snapshot", snap as Row[]);
  return flags;
}

// ---------------------------------------------------------------- transforms
interface Report { detected: string[]; counts: Record<string, number>; names: Record<string, string>;
  volume: Record<string, string[]>; discontinued_seen: string[]; roster?: number; relink?: unknown; mode: string; }

// SLI loads STREAM: each file is parsed row-by-row and inserted in bounded
// batches, so memory never scales with file size (the real exports include a
// ~22 MB / ~100k-row file that OOM-killed the isolate when buffered). Only the
// compact fields the roster engine reads are retained, and only when a
// roster/license file is present (wantRoster) — otherwise nothing is held at all.
// Wisp normalization is applied per row using the header-derived decision.
async function loadSliStreaming(paths: string[], dry: boolean, report: Report, sliForRoster: Row[], wantRoster: boolean) {
  const counts = new Map<string, number>(); let total = 0, dropped = 0; const disc = new Set<string>();
  let up: string | null = null;
  if (!dry) { up = await sourceUpload("sli_response", report.names.sli || "sli", 0); await clearTable("sli_response"); }
  let batch: Row[] = [];
  const flush = async () => { if (batch.length) { const b = batch; batch = []; await insertRows("sli_response", b); } };
  for (const p of paths) {
    const base = p.split("/").pop()!;
    let norm: { partner: string | null; dueKey: string | null } | null = null; let seenHeader = false;
    const stream = (await objBody(p)).pipeThrough(new TextDecoderStream()).pipeThrough(new CsvParseStream({ skipFirstRow: true }));
    for await (const rr of stream) {
      const r = rr as unknown as Row;
      if (!seenHeader) {
        seenHeader = true; norm = sliNormalizer(Object.keys(r), base);
        if (norm) report.detected.push(`sli normalized (${base}) — partner=${norm.partner ?? "—"}${norm.dueKey ? `, due←"${norm.dueKey}"` : ""}`);
      }
      if (norm) { if (norm.partner && !s(r["Partner"])) r["Partner"] = norm.partner; if (norm.dueKey && !s(r["SLI Due Time"])) r["SLI Due Time"] = r[norm.dueKey]; }
      if (isDiscontinued(r["Partner"])) { dropped++; if (r["Partner"]) disc.add(r["Partner"]); continue; }
      if (wantRoster) sliForRoster.push({ Clinician: r["Clinician"], Partner: r["Partner"], "Program Name": r["Program Name"],
        "Consult Type": r["Consult Type"], "Consult GUID": r["Consult GUID"], State: r["State"], "SLI Completed": r["SLI Completed"], "SLI Received": r["SLI Received"] });
      const pn = s(r["Partner"]); if (pn) counts.set(pn, (counts.get(pn) || 0) + 1);
      total++;
      if (!dry) {
        const biz = s(r["SLI During Biz Hrs?"]);
        batch.push({ consult_guid: s(r["Consult GUID"]), clinician_name_raw: s(r["Clinician"]), partner: s(r["Partner"]),
          program: s(r["Program Name"]), state: s(r["State"]), consult_type: s(r["Consult Type"]),
          sli_received: isoDT(pdt(r["SLI Received"])), sli_due: isoDT(pdt(r["SLI Due Time"])), sli_completed: isoDT(pdt(r["SLI Completed"])),
          sli_status_raw: s(r["SLI Status"]), during_biz_hrs: biz ? (biz.toLowerCase() === "yes") : null, source_upload_id: up });
        if (batch.length >= 1000) await flush();
      }
    }
  }
  report.detected.push(`sli: ${total} rows${dropped ? ` (${dropped} discontinued dropped)` : ""}`);
  disc.forEach(d => report.discontinued_seen.push(d));
  report.counts.sli_response = total;
  if (!dry) { await flush(); report.volume.sli = await volumeAlert("sli_response", counts, up!); await patchSourceCount(up!, total); }
}
async function loadShift(src: Row[], credByEmail: Map<string, string>, dry: boolean, report: Report) {
  const rows: Row[] = [];
  for (const r of src) {
    const h = parseFloat(r["Hours"] || "0") || 0; const em = (r["User"] || "").trim().toLowerCase();
    rows.push({ shift_type: s(r["Shift Type"]), service_line: s(r["Entity Name"]), start_at: isoDT(pdt(r["Start Time"])),
      end_at: isoDT(pdt(r["End Time"])), hours: h, clinician_email_raw: em || null,
      clinician_name_raw: (r["Name"] || "").trim().replace(/\b\w/g, (c: string) => c.toUpperCase()) || null,
      clinician_cred: credByEmail.get(em) || null });
  }
  report.detected.push(`shift: ${rows.length} rows`);
  if (dry) { report.counts.shift = rows.length; return; }
  const up = await sourceUpload("shift", report.names.shift || "shift", rows.length);
  for (const x of rows) x.source_upload_id = up;
  await clearTable("shift"); report.counts.shift = await insertRows("shift", rows);
}
async function loadIncentive(src: Row[], dry: boolean, report: Report) {
  const rows: Row[] = []; let dropped = 0; const disc = new Set<string>();
  for (const r of src) {
    if (isDiscontinued(r["Partner Name"])) { dropped++; if (r["Partner Name"]) disc.add(r["Partner Name"]); continue; }
    const cents = Math.round((parseFloat(r["Amount"] || "0") || 0) * 100);
    rows.push({ consult_guid: s(r["Consult Guid"]), partner: s(r["Partner Name"]), program: s(r["Program Name"]), state: s(r["States"]),
      consult_type: s(r["Consult Type"]), launched_at: isoDT(pdt(r["Launched Time"])), amount_cents: cents,
      currency: (r["Amount Currency"] || "USD").trim(), incentive_name: s(r["Incentive Name"]), budget_name: s(r["Budget Name"]),
      license_type: s(r["License Type"]), clinician_name_raw: s(r["Clinician Full Name"]),
      clinician_email_raw: (r["Clinician Email"] || "").trim().toLowerCase() || null });
  }
  report.detected.push(`incentive: ${rows.length} rows${dropped ? ` (${dropped} discontinued dropped)` : ""}`);
  disc.forEach(d => report.discontinued_seen.push(d));
  if (dry) { report.counts.incentive = rows.length; return; }
  const up = await sourceUpload("incentive", report.names.incentive || "incentive", rows.length);
  for (const x of rows) x.source_upload_id = up;
  await clearTable("incentive"); report.counts.incentive = await insertRows("incentive", rows);
}
// deno-lint-ignore no-explicit-any
async function loadConsult(paths: string[], dry: boolean, report: Report, forRoster: any) {
  const C = new Map<string, Row>(); const distinctGuid = new Set<string>(); let dropped = 0; const disc = new Set<string>();
  const onRow = (r: Row) => {
    const g = (r["Consult GUID"] || "").trim(); if (!g) return;
    if (isDiscontinued(r["Partner Name"])) { dropped++; if (r["Partner Name"]) disc.add(r["Partner Name"]); return; }
    let c = C.get(g);
    if (!c) { c = { partner: s(r["Partner Name"]), program: s(r["Program Name"]), ctype: s(r["Consult Type"]),
      created: isoDT(pdt(r["Consult Created At"])), hasInCall: false, earliestWorked: null, earliestWorkedIso: null,
      latestTs: null, latestIso: null, latestStatus: null, latestWorkedTs: null, latestWorkedGuid: null, latestWorkedName: null, latestWorkedEmail: null, nTouches: 0, nWorked: 0 }; C.set(g, c); }
    const d = pdt(r["Consult Status Created At"]); if (!d) return;
    const ts = epoch(d); const iso = isoDT(d); const statusId = (r["Consult Status ID"] || "").trim();
    c.nTouches++;
    if (statusId === "in_call") c.hasInCall = true;
    if (c.latestTs === null || ts >= c.latestTs) { c.latestTs = ts; c.latestIso = iso; c.latestStatus = statusId; }
    if (WORKED.has(statusId)) { c.nWorked++;
      if (c.earliestWorked === null || ts < c.earliestWorked) { c.earliestWorked = ts; c.earliestWorkedIso = iso; }
      if (c.latestWorkedTs === null || ts >= c.latestWorkedTs) { c.latestWorkedTs = ts; c.latestWorkedGuid = s(r["Clinician GUID"]); c.latestWorkedName = s(r["Clinician Display Name"]); c.latestWorkedEmail = s(r["Clinician Email"]); } }
    const cg = (r["Clinician GUID"] || "").trim();
    if (cg && cg.length >= 8) {
      if (!distinctGuid.has(cg)) { distinctGuid.add(cg); forRoster.tuples.push({ name: s(r["Clinician Display Name"]), email: s(r["Clinician Email"]), guid: cg }); }
      let a = forRoster.act.get(cg);
      if (!a) { a = { name: s(r["Clinician Display Name"]), email: s(r["Clinician Email"]), partners: new Set(), programs: new Set(), modalities: new Set(), consults: new Set(), last: null }; forRoster.act.set(cg, a); }
      const dd = isoDate(d);
      addSetV(a.partners, r["Partner Name"]); addSetV(a.programs, r["Program Name"]); addSetV(a.modalities, r["Consult Type"]); addSetV(a.consults, r["Consult GUID"]);
      if (dd && (a.last === null || dd > a.last)) a.last = dd;
    }
  };
  for (const p of paths) await streamConsult(p, onRow);
  const rows: Row[] = []; const counts = new Map<string, number>();
  for (const [g, c] of C) {
    if (c.latestTs === null) continue;
    const fw = c.earliestWorked;
    const prim = c.nWorked > 0 ? { guid: c.latestWorkedGuid, name: c.latestWorkedName, email: c.latestWorkedEmail } : { guid: null, name: null, email: null };
    const hs = (fw !== null && c.latestTs >= fw) ? Math.round(c.latestTs - fw) : null;
    rows.push({ consult_guid: g, partner: c.partner, program: c.program, consult_type: c.ctype,
      modality_class: modality(c.ctype, c.hasInCall), created_at: c.created, first_worked_at: c.earliestWorkedIso,
      final_status: c.latestStatus, final_status_at: c.latestIso, n_touches: c.nTouches, n_worked_touches: c.nWorked,
      handle_seconds: hs, clinician_guid: prim.guid, clinician_name_raw: prim.name, clinician_email_raw: prim.email });
    if (c.partner) counts.set(c.partner, (counts.get(c.partner) || 0) + 1);
  }
  report.detected.push(`consult: ${rows.length} consults${dropped ? ` (${dropped} discontinued touches dropped)` : ""}`);
  disc.forEach(d => report.discontinued_seen.push(d));
  if (dry) { report.counts.consult = rows.length; return; }
  const up = await sourceUpload("consult_touch_log", report.names.consult || "consult", rows.length);
  for (const x of rows) x.source_upload_id = up;
  report.volume.consult = await volumeAlert("consult", counts, up);
  await clearTable("consult"); report.counts.consult = await insertRows("consult", rows);
}

// ---------------------------------------------------------------- handler
async function isAdminCaller(authHeader: string): Promise<boolean> {
  try {
    const r = await fetch(`${REST}/rpc/whoami`, { method: "POST", headers: { apikey: ANON, Authorization: authHeader, "Content-Type": "application/json" }, body: "{}" });
    if (!r.ok) return false; const who = await r.json(); return !!(who && who.is_admin === true);
  } catch { return false; }
}
function consultInline(text: string) {
  const tuples: Row[] = []; const act = new Map<string, Row>(); const seen = new Set<string>();
  for (const r of parseCsv(text)) {
    const g = (r["Clinician GUID"] || "").trim(); if (!(g && g.length >= 8)) continue;
    const d = pdt(r["Consult Status Created At"]); const dd = isoDate(d);
    if (!seen.has(g)) { seen.add(g); tuples.push({ name: s(r["Clinician Display Name"]), email: s(r["Clinician Email"]), guid: g }); }
    let a = act.get(g); if (!a) { a = { name: s(r["Clinician Display Name"]), email: s(r["Clinician Email"]), partners: new Set(), programs: new Set(), modalities: new Set(), consults: new Set(), last: null }; act.set(g, a); }
    addSetV(a.partners, r["Partner Name"]); addSetV(a.programs, r["Program Name"]); addSetV(a.modalities, r["Consult Type"]); addSetV(a.consults, r["Consult GUID"]);
    if (dd && (a.last === null || dd > a.last)) a.last = dd;
  }
  return { tuples, act };
}

Deno.serve(async (req: Request) => {
  const acrh = req.headers.get("Access-Control-Request-Headers");
  const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": acrh || "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const J = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const body = await req.json().catch(() => ({}));
    const mode: string = body.mode || "dry";
    const auth = req.headers.get("Authorization") || "";

    if (mode === "roster-test") {
      const f: Row = body.files || {};
      const ci = f.consult ? consultInline(f.consult) : { tuples: [], act: new Map() };
      const { rows } = buildRoster({
        roster: f.roster ? parseCsv(f.roster) : undefined, license: f.license ? parseCsv(f.license) : undefined,
        sli: f.sli ? parseCsv(f.sli) : undefined, incentive: f.incentive ? parseCsv(f.incentive) : undefined,
        shift: f.shift ? parseCsv(f.shift) : undefined, consultTuples: ci.tuples, consultAct: ci.act,
      }, new Set(), {});
      return J({ ok: true, roster: rows });
    }

    if (!await isAdminCaller(auth)) return J({ error: "admin access required" }, 403);
    const dry = mode !== "load";
    const paths: string[] = body.paths || [];
    if (!paths.length) return J({ error: "no files provided" }, 400);
    const report: Report = { detected: [], counts: {}, names: {}, volume: {}, discontinued_seen: [], mode };

    // classify every file; MANY files can share a type — exports are split by
    // service line / modality (e.g. WSL_sync, CSL_async, TC all detect as sli).
    const byType: Record<string, string[]> = {};
    for (const p of paths) {
      const base = p.split("/").pop()!;
      const typ = detect(await headersOfPath(p));
      if (typ) { (byType[typ] ||= []).push(p); report.detected.push(`${typ} <- ${base}`); }
      else report.detected.push(`unrecognized: ${base}`);
    }
    for (const t of Object.keys(byType)) report.names[t] = byType[t].map(p => p.split("/").pop()).join(", ");

    // concatenate every file of a type (small types buffered; consult streams)
    const rowsOfType = async (typ: string): Promise<Row[]> => {
      const out: Row[] = [];
      for (const p of byType[typ] || []) for (const r of parseCsv(await downloadText(p))) out.push(r);
      return out;
    };
    const rosterRows = byType.roster ? await rowsOfType("roster") : [];
    const licenseRows = byType.license ? await rowsOfType("license") : [];
    const incRows = byType.incentive ? await rowsOfType("incentive") : [];
    const shiftRows = byType.shift ? await rowsOfType("shift") : [];
    // SLI streams (loadSliStreaming) so a ~22 MB file never lands in memory; it
    // populates sliForRoster only when a roster/license file is present to build.
    const wantRoster = !!(byType.roster || byType.license);
    const sliForRoster: Row[] = [];

    const forRoster = { tuples: [] as Row[], act: new Map<string, Row>() };
    if (byType.consult) await loadConsult(byType.consult, dry, report, forRoster);
    // Stream + load SLI first so the roster build below sees the (normalized) SLI
    // activity via sliForRoster; the insert itself is bounded-memory batches.
    if (byType.sli) await loadSliStreaming(byType.sli, dry, report, sliForRoster, wantRoster);

    let credByEmail = new Map<string, string>();
    if (rosterRows.length || licenseRows.length) {
      const { confirmed, overrides } = dry ? { confirmed: new Set<string>(), overrides: {} } : await fetchDecisions();
      const built = buildRoster({ roster: rosterRows, license: licenseRows, sli: sliForRoster, incentive: incRows, shift: shiftRows, consultTuples: forRoster.tuples, consultAct: forRoster.act }, confirmed, overrides);
      credByEmail = built.credByEmail;
      report.roster = built.rows.length;
      if (!dry) { const up = await sourceUpload("clinician_roster", report.names.roster || report.names.license || "roster", built.rows.length);
        for (const x of built.rows) x.source_upload_id = up;
        await clearTable("clinician_roster"); report.counts.clinician_roster = await insertRows("clinician_roster", built.rows); }
    }
    if (byType.shift) await loadShift(shiftRows, credByEmail, dry, report);
    if (byType.incentive) await loadIncentive(incRows, dry, report);
    if (!dry) report.relink = await relink();
    report.discontinued_seen = [...new Set(report.discontinued_seen)];
    return J({ ok: true, ...report });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
