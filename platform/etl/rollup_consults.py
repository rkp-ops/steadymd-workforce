#!/usr/bin/env python3
"""Roll up the 570K-touch Metabase status log into 176K consults with real
handle-time timings, then bulk-load into the canonical consult table via REST.
Dedup key = Consult GUID. 'Worked' statuses mirror the meaningful_status table."""
import gzip, csv, json, sys, time
from datetime import datetime
from collections import defaultdict
import requests

B = "/root/.claude/uploads/a6460d8f-83c0-5e4a-9439-826dbd972ec2/"
F = B + "99464b98-consult_status_updates_with_clinician_20260624T17_56_09.26615400804_00.csv.gz"
URL = "https://eeszygextbqglayglvfm.supabase.co/rest/v1"
KEY = "sb_publishable_txIrKbYtv9kjSKXjQVJFbw_hzUsLNEK"
H = {"apikey": KEY, "Authorization": f"Bearer {KEY}",
     "Content-Type": "application/json", "Prefer": "return=minimal"}
UPLOAD = "5c11333b-7002-4844-b2b5-2472f68eea64"
WORKED = {"completed", "rejected", "referred_out", "lab_approved", "lab_submitted", "in_call"}

def pdt(s):
    s = (s or "").strip()
    for f in ("%B %d, %Y, %I:%M %p", "%B %d, %Y, %I:%M:%S %p"):
        try: return datetime.strptime(s, f)
        except: pass
    return None

# ---- accumulate touches per consult ----
C = {}   # guid -> dict
with gzip.open(F, "rt", encoding="utf-8-sig", errors="replace") as fh:
    for r in csv.DictReader(fh):
        g = r["Consult GUID"].strip()
        if not g: continue
        c = C.get(g)
        if c is None:
            c = C[g] = {"partner": r["Partner Name"].strip(),
                        "program": r["Program Name"].strip(),
                        "ctype": r["Consult Type"].strip(),
                        "created": pdt(r["Consult Created At"]),
                        "touches": []}
        st = r["Consult Status ID"].strip()
        ts = pdt(r["Consult Status Created At"])
        c["touches"].append((ts, st, r["Clinician GUID"].strip(),
                             r["Clinician Display Name"].strip(), r["Clinician Email"].strip()))

print(f"consults: {len(C)}  (from touch log)", flush=True)

def iso(d): return d.isoformat() if d else None

rows = []
for g, c in C.items():
    tt = [t for t in c["touches"] if t[0]]
    tt.sort(key=lambda x: x[0])
    if not tt: continue
    worked = [t for t in tt if t[1] in WORKED]
    first_worked = worked[0][0] if worked else None
    final = tt[-1]
    final_status, final_at = final[1], final[0]
    # primary clinician = who resolved it (last worked touch), else last touch
    prim = worked[-1] if worked else final
    hs = None
    if first_worked and final_at and final_at >= first_worked:
        hs = int((final_at - first_worked).total_seconds())
    rows.append({
        "consult_guid": g,
        "partner": c["partner"] or None,
        "program": c["program"] or None,
        "consult_type": c["ctype"] or None,
        "created_at": iso(c["created"]),
        "first_worked_at": iso(first_worked),
        "final_status": final_status,
        "final_status_at": iso(final_at),
        "n_touches": len(tt),
        "n_worked_touches": len(worked),
        "handle_seconds": hs,
        "clinician_guid": prim[2] or None,
        "clinician_name_raw": prim[3] or None,
        "clinician_email_raw": prim[4] or None,
        "source_upload_id": UPLOAD,
    })

print(f"rolled up {len(rows)} consult rows; loading…", flush=True)

ok = 0
for i in range(0, len(rows), 1000):
    chunk = rows[i:i+1000]
    for attempt in range(4):
        resp = requests.post(f"{URL}/consult", headers=H, data=json.dumps(chunk), timeout=180)
        if resp.status_code in (200, 201, 204):
            ok += len(chunk); break
        if resp.status_code in (502, 503, 504) and attempt < 3:
            time.sleep(2*(attempt+1)); continue
        print(f"  !! batch @{i} HTTP {resp.status_code}: {resp.text[:300]}", flush=True)
        sys.exit(1)
    if (i//1000) % 20 == 0:
        print(f"  {ok}/{len(rows)}", flush=True)
print(f"DONE loaded {ok} consults", flush=True)
