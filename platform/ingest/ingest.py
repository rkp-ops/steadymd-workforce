#!/usr/bin/env python3
"""
SteadyMD operational-data ingestion.

Drop the monthly exports into a folder and run:

    SUPABASE_SERVICE_KEY=... python ingest.py ./exports

Every recognized file is auto-detected by its columns (tolerant of renames),
normalized, and loaded into Supabase. Recognized types:

    roster      Combined Clinician License Roster   -> clinician_roster (+ identity)
    license     Clinicians License Detail           -> feeds identity + license states
    sli         Response Time Details By SLI         -> sli_response
    consult     consult_status_updates (Metabase)    -> consult (deduped, modality)
    shift       Shifts export                        -> shift
    incentive   Incentives export                    -> incentive

Nothing is hard-coded to a filename; a file is classified by which columns it
carries, so a renamed file or column still lands correctly. Loads use the
service-role key (bypasses RLS) and are idempotent per source: the target rows
for that source are cleared, then reloaded.

This consolidates the one-off build scripts into a single repeatable step. The
heavy consult file (500k+ rows) is why this is a script and not an in-browser
upload — a browser can't parse a 30 MB+ export.
"""
import os, sys, csv, gzip, re, json, time
from datetime import datetime, date, timedelta
from collections import defaultdict
import requests

# ---------------------------------------------------------------- config
BASE = os.environ.get("SUPABASE_URL", "https://eeszygextbqglayglvfm.supabase.co").rstrip("/")
URL = BASE + "/rest/v1"
KEY = os.environ.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_KEY")
REF = date(2026, 7, 7)                 # "today" for active/inactive; override via --ref
ACTIVE = timedelta(days=90)
CREDS = {'md','do','np','pa','fnp','rn','dnp','phd','aprn','crnp','pmhnp','agnp','whnp',
         'msn','apn','bc','ii','iii','jr','sr','faap','facp','lcsw','psyd','arnp','fnpc','fnpbc'}

DRY = bool(os.environ.get("DRY_RUN"))    # transform + count only, no writes (for validation)
def die(m): print("ERROR:", m); sys.exit(1)
if not KEY and not DRY:
    die("set SUPABASE_SERVICE_KEY (service-role key, from Supabase > Project Settings > API)")
H = {"apikey": KEY or "", "Authorization": "Bearer " + (KEY or ""), "Content-Type": "application/json"}

# ---------------------------------------------------------------- helpers
def norm(h): return re.sub(r'[^a-z0-9]', '', (h or '').lower())
def opn(p): return gzip.open(p, 'rt', encoding='utf-8-sig', errors='replace') if p.endswith('.gz') \
    else open(p, encoding='utf-8-sig', errors='replace')
def s(v): v = (v or '').strip(); return v or None
def pdt(v, fmts):
    v = (v or '').strip()
    for f in fmts:
        try: return datetime.strptime(v, f)
        except: pass
    return None
DT_SLASH = ("%m/%d/%Y %I:%M %p",); DT_ISO = ("%Y-%m-%d %H:%M:%S",)
DT_MB = ("%B %d, %Y, %I:%M %p", "%B %d, %Y, %I:%M:%S %p")

# ---------------------------------------------------------------- detection
SIGNATURES = {
    'shift':     ['entityname', 'hours', 'shifttype'],
    'license':   ['licensestate', 'licensenumber'],
    'incentive': ['incentivename', 'amount', 'budgetname'],
    'roster':    ['credential', 'licensedstates'],
    'sli':       ['slireceived', 'sliduetime', 'slistatus'],
    'consult':   ['consultstatusid', 'consultstatuscreatedat'],
}
def headers_of(path):
    with opn(path) as fh:
        return next(csv.reader(fh))
def detect(headers):
    hs = [norm(h) for h in headers]
    best, best_score = None, 0
    for typ, sig in SIGNATURES.items():
        score = sum(1 for c in sig if any(c == h or c in h for h in hs))
        if score >= len(sig) - (0 if len(sig) == 2 else 1) and score > best_score:
            best, best_score = typ, score
    return best

# ---------------------------------------------------------------- loading
def clear(table):
    if DRY: return
    # idempotent: delete every row (id is never null), so a re-run replaces the source
    r = requests.delete(f"{URL}/{table}?id=not.is.null", headers={**H, "Prefer": "return=minimal"}, timeout=120)
    if r.status_code not in (200, 204):
        die(f"clear {table} -> HTTP {r.status_code}: {r.text[:300]}")
def insert(table, rows, batch=1000):
    if DRY: return len(rows)
    ok = 0
    for i in range(0, len(rows), batch):
        chunk = rows[i:i+batch]
        for a in range(4):
            r = requests.post(f"{URL}/{table}", headers={**H, "Prefer": "return=minimal"},
                              data=json.dumps(chunk), timeout=180)
            if r.status_code in (200, 201, 204): ok += len(chunk); break
            if r.status_code in (502, 503, 504) and a < 3: time.sleep(2 * (a + 1)); continue
            die(f"insert {table} @{i} -> HTTP {r.status_code}: {r.text[:300]}")
    return ok
def source_upload(kind, filename, n):
    if DRY: return "00000000-0000-0000-0000-000000000000"
    r = requests.post(f"{URL}/source_upload", headers={**H, "Prefer": "return=representation"},
                      data=json.dumps({"source_kind": kind, "filename": os.path.basename(filename), "row_count": n}),
                      timeout=60)
    if r.status_code not in (200, 201): die(f"source_upload -> HTTP {r.status_code}: {r.text[:200]}")
    return r.json()[0]["id"]
def fetch_decisions():
    """Identity memory + admin corrections made in the console, applied on every run
    so a data refresh keeps confirmations, credential/state fixes, and removals.
    Returns (confirmed_name_keys, overrides) where overrides is
    {name_key: {'credential':str, 'states':[...], 'removed':bool}}."""
    if DRY or not KEY: return frozenset(), {}
    try:
        r = requests.get(f"{URL}/roster_decision?select=name_key,decision,credential,states", headers=H, timeout=60)
        if r.status_code != 200:
            print(f"  note: roster_decision unreadable (HTTP {r.status_code}); corrections skipped")
            return frozenset(), {}
        confirmed, overrides = set(), {}
        for d in r.json():
            nk = d.get("name_key")
            if not nk: continue
            if d.get("decision") == "confirmed": confirmed.add(nk)
            ov = {}
            if d.get("decision") == "dismissed": ov["removed"] = True
            if d.get("credential"): ov["credential"] = d["credential"]
            if d.get("states") is not None: ov["states"] = d["states"]
            if ov: overrides[nk] = ov
        return frozenset(confirmed), overrides
    except Exception as e:
        print(f"  note: roster_decision fetch failed ({e}); corrections skipped")
        return frozenset(), {}
def rest_get(pathq):
    try:
        r = requests.get(f"{URL}/{pathq}", headers=H, timeout=60)
        return r.json() if r.status_code == 200 else None
    except Exception:
        return None

VOL_MIN = 20          # ignore swings on partners smaller than this (noise)
VOL_RATIO = 1.6       # flag a partner whose volume grew/shrank by ~60%+
def volume_alert(source_kind, rows, partner_key="partner", upload_id=None):
    """Compare this load's per-partner volume to the previous load and flag any
    partner that vanished, appeared, or swung hard — the fingerprint of a partial
    or doubled export. A no-op on dry runs (no DB to compare against)."""
    if DRY or not KEY: return
    new = defaultdict(int)
    for x in rows:
        p = x.get(partner_key)
        if p: new[p] += 1
    prior_rows = rest_get(f"ingest_partner_snapshot?source_kind=eq.{source_kind}"
                          f"&order=created_at.desc&limit=5000") or []
    if prior_rows:
        latest = prior_rows[0]["created_at"]
        prev = {r["partner"]: r["n"] for r in prior_rows if r["created_at"] == latest}
        when = latest[:10]
        flags = []
        for p in sorted(set(new) | set(prev)):
            a, b = prev.get(p, 0), new.get(p, 0)            # a=before, b=after
            if a >= VOL_MIN and b == 0:
                flags.append((0, "DISAPPEARED", p, f"{a:>6,} → 0"))
            elif b >= VOL_MIN and a == 0:
                flags.append((1, "NEW", p, f"     0 → {b:,}"))
            elif a > 0 and b > 0 and max(a, b) >= VOL_MIN and (max(a, b) / min(a, b)) >= VOL_RATIO:
                flags.append((2, f"{(b-a)/a*100:+.0f}%", p, f"{a:>6,} → {b:,}"))
        print(f"  volume check — {source_kind} vs previous load ({when}):")
        if flags:
            for _, lab, p, detail in sorted(flags, key=lambda f: f[0]):
                print(f"  ⚠ {lab:12} {p[:26]:26} {detail}")
            rest = len(set(new) | set(prev)) - len(flags)
            print(f"    ({rest} partner{'' if rest == 1 else 's'} within range)")
        else:
            print(f"    {len(new)} partners, all within range of the previous load")
    else:
        print(f"  volume check — {source_kind}: first load, baseline saved (no prior to compare)")
    snap = [{"source_kind": source_kind, "partner": p, "n": n, "source_upload_id": upload_id}
            for p, n in new.items()]
    if snap: insert("ingest_partner_snapshot", snap)

# ---------------------------------------------------------------- transforms
def rows_of(path):
    with opn(path) as fh:
        yield from csv.DictReader(fh)

def load_sli(path):
    up = None; rows = []
    for r in rows_of(path):
        biz = s(r.get("SLI During Biz Hrs?"))
        rows.append({
            "consult_guid": s(r.get("Consult GUID")), "clinician_name_raw": s(r.get("Clinician")),
            "partner": s(r.get("Partner")), "program": s(r.get("Program Name")), "state": s(r.get("State")),
            "consult_type": s(r.get("Consult Type")),
            "sli_received": iso(pdt(r.get("SLI Received"), DT_ISO)), "sli_due": iso(pdt(r.get("SLI Due Time"), DT_ISO)),
            "sli_completed": iso(pdt(r.get("SLI Completed"), DT_ISO)), "sli_status_raw": s(r.get("SLI Status")),
            "during_biz_hrs": (biz.lower() == "yes") if biz else None,
        })
    up = source_upload("sli_response", path, len(rows))
    for x in rows: x["source_upload_id"] = up
    volume_alert("sli_response", rows, "partner", up)
    clear("sli_response"); return insert("sli_response", rows)

LAB_TYPES = {"lab-order", "async_lab_order", "async_lab_result"}
WORKED = {"completed", "rejected", "referred_out", "in_call"}
def modality(ctype, statuses):
    if ctype in LAB_TYPES: return "lab"
    if (ctype or "").startswith("critical_values_phone_call"): return "sync_phone"
    if "in_call" in statuses: return "sync_video"
    if ctype in ("async_messaging", "chart_review"): return "messaging"
    return "other"
def iso(d): return d.isoformat() if d else None
def load_consult(path):
    C = {}
    for r in rows_of(path):
        g = (r.get("Consult GUID") or "").strip()
        if not g: continue
        c = C.get(g)
        if c is None:
            c = C[g] = {"partner": s(r.get("Partner Name")), "program": s(r.get("Program Name")),
                        "ctype": s(r.get("Consult Type")), "created": pdt(r.get("Consult Created At"), DT_MB), "t": []}
        c["t"].append((pdt(r.get("Consult Status Created At"), DT_MB), (r.get("Consult Status ID") or "").strip(),
                       s(r.get("Clinician GUID")), s(r.get("Clinician Display Name")), s(r.get("Clinician Email"))))
    up = source_upload("consult_touch_log", path, sum(len(c["t"]) for c in C.values()))
    rows = []
    for g, c in C.items():
        tt = sorted([x for x in c["t"] if x[0]], key=lambda x: x[0])
        if not tt: continue
        statuses = {x[1] for x in tt}
        worked = [x for x in tt if x[1] in WORKED]
        fw = worked[0][0] if worked else None
        final = tt[-1]; prim = worked[-1] if worked else final
        hs = int((final[0] - fw).total_seconds()) if (fw and final[0] >= fw) else None
        rows.append({"consult_guid": g, "partner": c["partner"], "program": c["program"], "consult_type": c["ctype"],
                     "modality_class": modality(c["ctype"], statuses), "created_at": iso(c["created"]),
                     "first_worked_at": iso(fw), "final_status": final[1], "final_status_at": iso(final[0]),
                     "n_touches": len(tt), "n_worked_touches": len(worked), "handle_seconds": hs,
                     "clinician_guid": prim[2], "clinician_name_raw": prim[3], "clinician_email_raw": prim[4],
                     "source_upload_id": up})
    volume_alert("consult", rows, "partner", up)
    clear("consult"); return insert("consult", rows)

def load_shift(path, cred_by_email):
    rows = []
    for r in rows_of(path):
        try: h = float(r.get("Hours") or 0)
        except: h = 0.0
        em = (r.get("User") or "").strip().lower()
        rows.append({"shift_type": s(r.get("Shift Type")), "service_line": s(r.get("Entity Name")),
                     "start_at": iso(pdt(r.get("Start Time"), DT_SLASH)), "end_at": iso(pdt(r.get("End Time"), DT_SLASH)),
                     "hours": h, "clinician_email_raw": em or None,
                     "clinician_name_raw": (r.get("Name") or "").strip().title() or None,
                     "clinician_cred": cred_by_email.get(em)})
    up = source_upload("shift", path, len(rows))
    for x in rows: x["source_upload_id"] = up
    clear("shift"); return insert("shift", rows)

def load_incentive(path):
    rows = []
    for r in rows_of(path):
        try: cents = int(round(float(r.get("Amount") or 0) * 100))
        except: cents = 0
        rows.append({"consult_guid": s(r.get("Consult Guid")), "partner": s(r.get("Partner Name")),
                     "program": s(r.get("Program Name")), "state": s(r.get("States")),
                     "consult_type": s(r.get("Consult Type")), "launched_at": iso(pdt(r.get("Launched Time"), DT_ISO)),
                     "amount_cents": cents, "currency": (r.get("Amount Currency") or "USD").strip(),
                     "incentive_name": s(r.get("Incentive Name")), "budget_name": s(r.get("Budget Name")),
                     "license_type": s(r.get("License Type")), "clinician_name_raw": s(r.get("Clinician Full Name")),
                     "clinician_email_raw": (r.get("Clinician Email") or "").strip().lower() or None})
    up = source_upload("incentive", path, len(rows))
    for x in rows: x["source_upload_id"] = up
    clear("incentive"); return insert("incentive", rows)

# ---------------------------------------------------------------- main
def main(folder):
    files = [os.path.join(folder, f) for f in sorted(os.listdir(folder))
             if f.lower().endswith((".csv", ".csv.gz"))]
    if not files: die(f"no .csv / .csv.gz files in {folder}")
    found = {}
    for p in files:
        try: typ = detect(headers_of(p))
        except Exception as e: print(f"  skip {os.path.basename(p)} (unreadable: {e})"); continue
        if typ: found.setdefault(typ, p); print(f"  detected {typ:9} <- {os.path.basename(p)}")
        else:   print(f"  ?? unrecognized: {os.path.basename(p)}")

    # roster identity needs credential-by-email; build it from roster/license first
    cred_by_email = {}
    from identity_lib import build_roster            # proven engine, packaged alongside
    if 'roster' in found or 'license' in found:
        _conf, _ov = fetch_decisions()
        roster_rows, cred_by_email = build_roster(found, REF, ACTIVE, _conf, _ov)
        up = source_upload("clinician_roster", found.get('roster', found.get('license')), len(roster_rows))
        for x in roster_rows: x["source_upload_id"] = up
        clear("clinician_roster"); n = insert("clinician_roster", roster_rows)
        print(f"  loaded clinician_roster: {n}")

    if 'sli' in found:       print(f"  loaded sli_response: {load_sli(found['sli'])}")
    if 'consult' in found:   print(f"  loaded consult: {load_consult(found['consult'])}")
    if 'shift' in found:     print(f"  loaded shift: {load_shift(found['shift'], cred_by_email)}")
    if 'incentive' in found: print(f"  loaded incentive: {load_incentive(found['incentive'])}")
    print("done — the console reads these live on next refresh.")

if __name__ == "__main__":
    if len(sys.argv) < 2: die("usage: python ingest.py <folder-of-exports>")
    main(sys.argv[1])
