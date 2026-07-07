#!/usr/bin/env python3
"""Recompute the Performance aggregates from the raw SLI export using the exact
Completed-vs-Due logic the DB uses (sla_met = completed <= due), so the console
numbers match the live Supabase figures to the row."""
import csv, json, statistics
from datetime import datetime
from collections import defaultdict

B = "/root/.claude/uploads/a6460d8f-83c0-5e4a-9439-826dbd972ec2/"
OUT = "/tmp/claude-0/-home-user-steadymd-workforce/a6460d8f-83c0-5e4a-9439-826dbd972ec2/scratchpad/perf.json"

def pdt(s):
    s = (s or "").strip()
    if not s: return None
    try: return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
    except: return None

rows = []
with open(B + "e7c34be3-Response_Time_Details_By_SLI_Download_80.csv",
          encoding="utf-8-sig", errors="replace") as fh:
    for r in csv.DictReader(fh):
        rec = pdt(r.get("SLI Received")); due = pdt(r.get("SLI Due Time")); comp = pdt(r.get("SLI Completed"))
        met = (comp <= due) if (comp and due) else None
        wait = (comp - rec).total_seconds() if (comp and rec) else None
        rows.append(dict(
            partner=(r.get("Partner") or "").strip(),
            program=(r.get("Program Name") or "").strip(),
            state=(r.get("State") or "").strip(),
            ctype=(r.get("Consult Type") or "").strip(),
            biz=(r.get("SLI During Biz Hrs?") or "").strip().lower() == "yes",
            due=due, met=met, wait=wait))

def grp(key, waits=False, top=None):
    g = defaultdict(lambda: [0, 0, []])   # n, met, waits
    for r in rows:
        k = r[key]
        if not k: continue
        g[k][0] += 1
        if r["met"]: g[k][1] += 1
        if r["wait"] is not None: g[k][2].append(r["wait"])
    out = []
    for k, (n, m, w) in g.items():
        rec = {"name": k, "n": n, "met": m, "pct": round(100.0*m/n, 1)}
        if waits and w: rec["avg_wait_s"] = round(sum(w)/len(w))
        out.append(rec)
    out.sort(key=lambda x: -x["n"])
    return out[:top] if top else out

# overall
allw = sorted(r["wait"] for r in rows if r["wait"] is not None)
n = len(rows); m = sum(1 for r in rows if r["met"])
overall = {"n": n, "met": m, "pct": round(100.0*m/n, 1),
           "avg_wait_s": round(sum(allw)/len(allw)),
           "p50_wait_s": round(statistics.median(allw)),
           "p90_wait_s": round(allw[int(len(allw)*0.9)])}

# business hours split
biz = defaultdict(lambda: [0, 0])
for r in rows:
    b = biz["Business hours" if r["biz"] else "After hours"]
    b[0] += 1
    if r["met"]: b[1] += 1
bizhrs = [{"name": k, "n": v[0], "pct": round(100.0*v[1]/v[0], 1)} for k, v in biz.items()]

# heatmap: pg-style dow (Sun=0..Sat=6) x hour
hm = defaultdict(lambda: [0, 0])
for r in rows:
    if not r["due"]: continue
    dow = (r["due"].weekday() + 1) % 7   # python Mon=0 -> pg Sun=0
    key = (dow, r["due"].hour)
    hm[key][0] += 1
    if r["met"]: hm[key][1] += 1
heatmap = [[d, h, v[0], round(100.0*v[1]/v[0], 1)] for (d, h), v in sorted(hm.items())]

# daily trend
day = defaultdict(lambda: [0, 0])
for r in rows:
    if not r["due"]: continue
    k = r["due"].date().isoformat()
    day[k][0] += 1
    if r["met"]: day[k][1] += 1
daily = [[k, v[0], round(100.0*v[1]/v[0], 1)] for k, v in sorted(day.items())]

# wait histogram
buckets = [("<1m",0,60),("1-5m",60,300),("5-15m",300,900),("15-30m",900,1800),
           ("30-60m",1800,3600),("1-4h",3600,14400),("4h+",14400,10**9)]
wh = []
for lab, lo, hi in buckets:
    wh.append([lab, sum(1 for w in allw if lo <= w < hi)])

perf = dict(
    range={"min": daily[0][0], "max": daily[-1][0]},
    overall=overall,
    partner=grp("partner", waits=True),
    program=grp("program", top=15),
    state=grp("state", top=16),
    ctype=grp("ctype"),
    bizhrs=bizhrs,
    heatmap=heatmap,
    daily=daily,
    wait_hist=wh,
)
json.dump(perf, open(OUT, "w"), separators=(",", ":"))
print("overall", overall)
print("partners", len(perf["partner"]), "heatmap cells", len(heatmap), "days", len(daily))
print("wrote", OUT)
