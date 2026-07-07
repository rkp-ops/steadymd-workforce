#!/usr/bin/env python3
"""Bulk-load the unified roster + SLI response rows into Supabase via PostgREST.
Runs from the sandbox so the row payloads never enter the model's token context.
Egress uses the agent proxy (HTTPS_PROXY) + CA bundle (REQUESTS_CA_BUNDLE), both
already in env. Anon insert is allowed only by the TEMPORARY tmp_load_* policies,
which get dropped immediately after this completes."""
import json, csv, sys, time
import requests

URL = "https://eeszygextbqglayglvfm.supabase.co/rest/v1"
KEY = "sb_publishable_txIrKbYtv9kjSKXjQVJFbw_hzUsLNEK"
H = {"apikey": KEY, "Authorization": f"Bearer {KEY}",
     "Content-Type": "application/json", "Prefer": "return=minimal"}
B = "/root/.claude/uploads/a6460d8f-83c0-5e4a-9439-826dbd972ec2/"
SCR = "/tmp/claude-0/-home-user-steadymd-workforce/a6460d8f-83c0-5e4a-9439-826dbd972ec2/scratchpad/"
ROSTER_UPLOAD = "b4d35088-cfd8-4130-b0a6-a29ac71ca00c"
SLI_UPLOAD = "34a4e0f5-b056-4301-863e-ef3276fb80c0"

def post_batches(table, rows, batch=500):
    ok = 0
    for i in range(0, len(rows), batch):
        chunk = rows[i:i+batch]
        for attempt in range(4):
            r = requests.post(f"{URL}/{table}", headers=H, data=json.dumps(chunk), timeout=120)
            if r.status_code in (200, 201, 204):
                ok += len(chunk); break
            if r.status_code in (502, 503, 504) and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            print(f"  !! {table} batch @{i} -> HTTP {r.status_code}: {r.text[:400]}", flush=True)
            sys.exit(1)
        print(f"  {table}: {ok}/{len(rows)}", flush=True)
    return ok

def s(v):
    v = (v or "").strip()
    return v or None

# ---------- clinician_roster ----------
roster = json.load(open(SCR + "roster.json"))
def arr(v): return v if isinstance(v, list) else []
rrows = [{
    "name": r.get("n") or "(unknown)",
    "credential": s(r.get("c")),
    "npi": s(r.get("npi")),
    "emails": arr(r.get("em")),
    "aliases": arr(r.get("al")),
    "license_states": arr(r.get("ls")),
    "active_states": arr(r.get("as")),
    "programs": arr(r.get("pr")),
    "partners": arr(r.get("pa")),
    "modalities": arr(r.get("mo")),
    "consult_count": int(r.get("ct") or 0),
    "shift_hours": float(r.get("sh") or 0),
    "incentive_usd": float(r.get("inc") or 0),
    "last_active": s(r.get("la")),
    "status": r.get("st") or "inactive",
    "source_upload_id": ROSTER_UPLOAD,
} for r in roster]
print(f"clinician_roster: prepared {len(rrows)} rows", flush=True)
post_batches("clinician_roster", rrows)

# ---------- sli_response ----------
srows = []
with open(B + "e7c34be3-Response_Time_Details_By_SLI_Download_80.csv",
          encoding="utf-8-sig", errors="replace") as fh:
    for row in csv.DictReader(fh):
        biz = s(row.get("SLI During Biz Hrs?"))
        srows.append({
            "consult_guid": s(row.get("Consult GUID")),
            "clinician_name_raw": s(row.get("Clinician")),
            "partner": s(row.get("Partner")),
            "program": s(row.get("Program Name")),
            "state": s(row.get("State")),
            "consult_type": s(row.get("Consult Type")),
            "sli_received": s(row.get("SLI Received")),
            "sli_due": s(row.get("SLI Due Time")),
            "sli_completed": s(row.get("SLI Completed")),
            "sli_status_raw": s(row.get("SLI Status")),
            "during_biz_hrs": (biz.lower() == "yes") if biz else None,
            "source_upload_id": SLI_UPLOAD,
        })
print(f"sli_response: prepared {len(srows)} rows", flush=True)
post_batches("sli_response", srows)
print("DONE", flush=True)
