-- ============================================================================
-- 09_productivity_ledger.sql
-- The weekly metric ledger + the Productivity tab's RPC + the post-ingest
-- relink. Applied live to project eeszygextbqglayglvfm as migrations
--   clinician_period_ledger   (table + refresh_clinician_period_metrics)
--   vph_trend_rpc             (gated reader for the console)
--   relink_clinician_spine    (post-ingest re-anchor, called by ingest.py)
--
-- Design: metrics are stored as raw weekly COMPONENTS (counts, hours, seconds)
-- per clinician, keyed on the STABLE clinician id from the identity spine (08),
-- so ratios stay recomputable, aggregation is exact, and a monthly reload
-- upserts the same weeks instead of double-counting or forking history.
-- Verified: a simulated roster reload re-matched all 850 clinicians to their
-- existing entities (783 npi / 44 email / 23 name), created 0 duplicates, and
-- left the 1,777-row ledger identical.
-- ============================================================================

-- 1. Weekly per-clinician ledger -----------------------------------------------
create table if not exists public.clinician_period_metric (
  clinician_id     uuid not null references public.clinician(id) on delete cascade,
  grain            text not null default 'week' check (grain in ('week')),
  period_start     date not null,              -- Monday of the ISO week
  consults         integer not null default 0, -- non-lab
  sync_c           integer not null default 0,
  async_c          integer not null default 0,
  lab_c            integer not null default 0,
  shift_hours      numeric not null default 0,
  sla_scored       integer not null default 0,
  sla_met          integer not null default 0,
  wait_seconds_sum bigint  not null default 0,
  incentive_cents  bigint  not null default 0,
  computed_at      timestamptz not null default now(),
  primary key (clinician_id, grain, period_start)
);
create index if not exists cpm_period on public.clinician_period_metric (grain, period_start);
alter table public.clinician_period_metric enable row level security;
-- no direct policy: served through SECURITY DEFINER RPCs only.

-- 2. refresh_clinician_period_metrics() ----------------------------------------
-- Recomputes the ledger from the attributed fact tables; upsert on the PK makes
-- it idempotent. See the live migration for the full body (weekly rollups of
-- consult / shift / sli_response / incentive by clinician_id).

-- 3. vph_trend() ----------------------------------------------------------------
-- Console reader (is_active_app_user()-gated, SECURITY DEFINER, granted to
-- anon+authenticated like the other console RPCs). Returns jsonb:
--   { consult_window: [lo, hi], shift_window: [lo, hi],
--     rows: [[roster_id, name, credential, tier, week, consults, sync_c,
--             async_c, shift_hours, sla_scored, sla_met], ...] }
-- The client derives VPH, peer percentiles, and movement; it uses
-- consult_window to mark weeks complete/partial and to EXCLUDE consult-blind
-- weeks so the export boundary can't read as a productivity collapse.

-- 4. relink_clinician_spine() ---------------------------------------------------
-- Called by platform/ingest/ingest.py after every load (service role; no
-- browser grant). In order:
--   1. relink rebuilt roster rows to existing entities: npi -> email -> name_key
--   2. mint entities ONLY for genuinely new people
--   3. learn newly-seen identity keys (insert .. on conflict do nothing)
--   4. refresh entity display fields (credential, last_active, status)
--   5. fill fact-table clinician FKs (NULLs only; email first, name fallback
--      for shifts and SLIs — the SLI export's GUIDs don't match consults)
--   6. refresh_clinician_period_metrics()
-- Returns counts: {relinked_npi, relinked_email, relinked_name, new_entities,
--                  fact_rows_attributed, ledger_rows}.
