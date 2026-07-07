# Platform ETL pipeline

Turns the six raw exports (roster, license detail, Aria SLI, Metabase consult
log, incentives, shifts) into the canonical Supabase model. Nothing here reads
raw files at query time — the reports read the clean model underneath, so a
renamed column or new file layout can't break a chart.

## Order

1. **`identity_engine.py`** — fuses all six exports into one row per real
   clinician via multi-key Union-Find (NPI / email / Metabase GUID are gold
   keys; names only bridge records when nothing contradicts). Emits the unified
   roster consumed by the console and loaded into `clinician_roster`.

2. **`load_supabase.py`** — bulk-loads `clinician_roster` (851) and
   `sli_response` (12,002) into Supabase via PostgREST. Runs from a sandbox so
   row payloads never enter an LLM context. Uses a TEMPORARY anon-insert policy
   that is dropped immediately after (see `db/02_serving_roster.sql`).

3. **`rollup_consults.py`** — rolls the 570,858-touch Metabase status log up to
   176,521 consults (dedup by Consult GUID), deriving handle-time timings and
   the "moved care forward" worked-status count, then loads `consult`. Worked
   statuses mirror the `meaningful_status` table (`db/03_consult_and_worked_status.sql`).

4. **`compute_perf.py`** — recomputes the Performance aggregates (SLA by
   partner/program/state, day×hour heatmap, wait distribution) from the raw SLI
   file using the exact Completed-vs-Due logic the DB uses, so the console
   figures match the live database to the row.

## Notes

- The Supabase key used here is the **publishable/anon** key (safe to expose);
  it only works because RLS gates every table on `is_active_app_user()`. Bulk
  loads open a temporary anon-insert policy and revoke it in the same session.
- Input paths point at the session upload dir; swap them for your own export
  locations when re-running.
