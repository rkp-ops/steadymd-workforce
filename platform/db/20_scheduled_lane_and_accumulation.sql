-- ============================================================================
-- 20_scheduled_lane_and_accumulation.sql
-- Applied live to project eeszygextbqglayglvfm as migration
-- `scheduled_lane_and_accumulation_keys`.
--
-- Phase 1 (data foundation) — two things:
--
--   1. SCHEDULED vs ON-DEMAND LANE. Scheduled care must never be combined with
--      on-demand in any on-demand-dominant metric (SLA, VPH/productivity, wait,
--      coverage-vs-demand, scoreboard). Scheduled visits carry a *slot* time as
--      their SLI `received` (due = received + ~10-min grace), so
--      "wait = completed - received" is meaningless and goes negative when the
--      visit runs before its slot. Signature in the data: Noom & Futur
--      *video_visit* / *scheduled_video consult types (10-min due-offset,
--      ~30-50% of rows complete before their slot). NOTE: a 10-min due-offset
--      alone is NOT the signal — Transcarent `urgent-care` also has one but is
--      genuinely on-demand (0 negatives). The reliable signal is the visit-type
--      NAME, so `lane` is classified from consult_type only.
--
--      Result after apply: on-demand negative waits = 0 (all 1,506 negatives are
--      isolated in the scheduled lane).
--
--   2. ACCUMULATION KEYS. The loader is moving from wipe-and-replace to
--      accumulate-by-id (upsert, newest-wins). These unique indexes are the
--      ON CONFLICT targets. Keys use SOURCE columns only (stable across the
--      roster re-derivation that reassigns the internal clinician_id):
--        consult    : consult_guid                                   (clean)
--        sli        : consult_guid + consult_type + sli_received     (per SLI leg)
--        shift      : clinician_email + start + end + line + type     (no source id)
--        incentive  : consult_guid + incentive_name + launched + amount
--
-- Pre-existing collisions were resolved first: ~196 SLI rows were contradictory
-- scheduled Met/Missed pairs (one completed before its slot, one after) — kept
-- the latest completion (the real record); ~7 shift duplicates — kept one.
-- ============================================================================

-- 1) Resolve pre-existing SLI collisions on the natural key — keep latest completion.
with ranked as (
  select ctid, row_number() over (
    partition by consult_guid, coalesce(consult_type,''), sli_received
    order by sli_completed desc nulls last, ctid
  ) rn
  from sli_response
)
delete from sli_response s using ranked r where s.ctid = r.ctid and r.rn > 1;

-- 2) Resolve shift duplicate natural keys — keep one.
with ranked as (
  select ctid, row_number() over (
    partition by coalesce(clinician_email_raw,''), start_at, end_at,
                 coalesce(service_line,''), coalesce(shift_type,'')
    order by ctid
  ) rn
  from shift
)
delete from shift s using ranked r where s.ctid = r.ctid and r.rn > 1;

-- 3) Lane classification (generated, auto-maintained for future upserts too).
alter table sli_response
  add column if not exists lane text
  generated always as (
    case when consult_type like '%video_visit%' or consult_type like '%scheduled_video%'
         then 'scheduled' else 'on_demand' end
  ) stored;
create index if not exists sli_lane_idx on sli_response (lane);

-- 4) Accumulation keys (unique indexes; coalesce gives a clean conflict target
--    for nullable key parts).
create unique index if not exists consult_guid_uk
  on consult (consult_guid);
create unique index if not exists sli_natural_uk
  on sli_response (consult_guid, coalesce(consult_type,''), sli_received);
create unique index if not exists shift_natural_uk
  on shift (coalesce(clinician_email_raw,''), start_at, end_at,
           coalesce(service_line,''), coalesce(shift_type,''));
create unique index if not exists incentive_natural_uk
  on incentive (consult_guid, incentive_name, launched_at, amount_cents);
