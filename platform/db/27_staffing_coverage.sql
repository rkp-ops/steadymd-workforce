-- ============================================================================
-- 27_staffing_coverage.sql — staffing-first coverage: bodies by hour/credential/state
--
-- Replaces the consults-per-clinician framing. Everything is expressed in BODIES.
--
-- Verdicts (operator-approved labels): Covered / Stretched / Exposed
--   Covered   scheduled bodies alone cover expected arrivals at the measured
--             on-shift clearance rate — no reliance on unscheduled pickup
--   Stretched schedule doesn't cover it, but the gap sits inside what off-shift
--             pickup has historically absorbed
--   Exposed   gap exceeds typical off-shift pickup (or a state has demand and
--             zero licensed body scheduled)
--
-- CALIBRATED FROM THIS OPERATION'S OWN HISTORY (Jun 1-24 overlap, TC excluded):
--   * on-shift async clearance ~7 per body-hour (median); demonstrated p80 ~12
--   * attainment holds >=97% up to ~13.5 async arrivals per SCHEDULED body-hour,
--     knee at ~13.5-17.75, collapse past ~18
--   * per ACTIVE body the curve is FLAT (96.9-98.0% across all load) because
--     69% of async and 29% of sync is cleared OFF-SHIFT by people who were never
--     scheduled. SLA is being held up by discretionary labor. That is the whole
--     point of the Stretched band -- it is a dependency warning, not spare capacity.
--   * sync: adding bodies does NOT move sync attainment in the observed range;
--     misses are structural (routing/queue/state mix). Sync therefore gets a hard
--     concurrency check (bodies vs arrivals x handle) and NO invented band.
--
-- SHARED-POOL RULE (critical): a clinician licensed in 20 states is ONE body, not
-- 20. Capacity math is only valid pool-wide; per-state we report bodies licensed &
-- scheduled and flag hard gaps (demand + zero licensed body), never a per-state
-- capacity verdict that double-counts the same person.
--
-- Every rate is a parameter with a measured default, so the operator can override.
-- Every window/day/hour/service-line/credential filter moves supply AND demand.
-- TC is siloed via service_line_map (count_in_coverage=false) — include it only by
-- naming it explicitly in p_service_line, and it is then reported ALONE.
-- ============================================================================

create or replace function public.staffing_coverage(
    p_from          date    default null,
    p_to            date    default null,
    p_base_weeks    int     default 4,
    p_service_line  text[]  default null,   -- null = all coverage-counted entities
    p_cred          text[]  default null,
    p_hour0         int     default 0,
    p_hour1         int     default 23,
    p_dow           int[]   default null,   -- isodow 1=Mon..7=Sun; null = all days
    p_clear_per_hr  numeric default 7,      -- measured on-shift async clearance
    p_sync_min      numeric default 17.3,   -- winsorized mean sync handle minutes
    p_offshift      numeric default 0.69)   -- historical off-shift share of async
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb; d_to date; d_from date; ndays numeric;
        v_bodies int; v_hours numeric; v_async numeric; v_sync numeric;
        v_cap numeric; v_load numeric; v_verdict text; v_stretch numeric;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;

  select max((sli_received at time zone 'America/Chicago')::date) into d_to
    from sli_response where lane='on_demand';
  if d_to is null then d_to := current_date; end if;
  d_from := d_to - (greatest(p_base_weeks,1)*7 - 1);

  -- Day-set defaults to the days the WINDOW actually spans, so a weekend window is
  -- compared against weekend demand (not a week-wide average). Explicit p_dow wins.
  if p_dow is null and p_from is not null and p_to is not null and (p_to - p_from) < 7 then
    select array_agg(distinct extract(isodow from g)::int)
      into p_dow from generate_series(p_from, p_to, interval '1 day') g;
  end if;

  -- temp tables are per-call scratch; drop first so repeated calls in one
  -- transaction (or a retried statement) can never collide.
  drop table if exists _sup; drop table if exists _dem;

  -- ---- SUPPLY: scheduled bodies, hour-expanded, filtered, credential-tagged ----
  create temp table _sup on commit drop as
  with ent as (
    select s.*, m.count_in_coverage, m.partner_label
    from shift s
    left join service_line_map m on m.entity = s.service_line
    where lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
      and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
      and (p_from is null or (s.start_at at time zone 'America/Chicago')::date >= p_from)
      and (p_to   is null or (s.start_at at time zone 'America/Chicago')::date <= p_to)
      and (case when p_service_line is not null then s.service_line = any(p_service_line)
                else coalesce(m.count_in_coverage,true) end)
  )
  select lower(e.clinician_email_raw) em,
         extract(isodow from h)::int dow, extract(hour from h)::int hr,
         h::date d,
         coalesce(public.cred_bucket(r.credential),'—') cred,
         r.id rid, r.license_states
  from ent e
  cross join lateral generate_series(
    date_trunc('hour', e.start_at at time zone 'America/Chicago'),
    (e.end_at at time zone 'America/Chicago') - interval '1 second', interval '1 hour') h
  left join clinician_roster r
    on lower(e.clinician_email_raw) = any(array(select lower(x) from unnest(r.emails) x))
  where extract(hour from h)::int between p_hour0 and p_hour1
    and (p_dow is null or extract(isodow from h)::int = any(p_dow))
    and (p_cred is null or coalesce(public.cred_bucket(r.credential),'—') = any(p_cred));

  select count(distinct em), count(*)::numeric into v_bodies, v_hours from _sup;

  -- ---- DEMAND: arrivals over the baseline, same hour/day filters, per day ----
  create temp table _dem on commit drop as
  select nullif(trim(state),'') st,
         case when consult_type ~* 'lab' then 'lab'
              when consult_type ~* 'critical_values_phone' then 'sync'
              when consult_type ~* 'message|async|chart' then 'async'
              when consult_type ~* 'video|urgent' then 'sync' else 'other' end modality,
         count(*)::numeric n,
         count(distinct (sli_received at time zone 'America/Chicago')::date) nd
  from sli_response sr
  where sr.lane='on_demand'
    and (sr.sli_received at time zone 'America/Chicago')::date between d_from and d_to
    and extract(hour from sr.sli_received at time zone 'America/Chicago')::int between p_hour0 and p_hour1
    and (p_dow is null or extract(isodow from sr.sli_received at time zone 'America/Chicago')::int = any(p_dow))
    -- demand follows the supply filter: tracked_only + siloed populations never
    -- blend into a pooled number; when a dedicated entity is selected, only its
    -- partner's demand counts.
    and not exists (select 1 from service_line_map m
                    where m.demand_match is not null and not m.count_in_sla
                      and sr.partner ilike '%'||m.demand_match||'%'
                      and (p_service_line is null or not (m.entity = any(p_service_line))))
    and (p_service_line is null or exists (
          select 1 from service_line_map m
          where m.entity = any(p_service_line)
            and (m.demand_match is null or sr.partner ilike '%'||m.demand_match||'%')))
  group by 1,2;

  select coalesce(sum(n)/nullif(max(nd),0),0) into v_async from _dem where modality='async';
  select coalesce(sum(n)/nullif(max(nd),0),0) into v_sync  from _dem where modality='sync';

  ndays   := greatest((case when p_from is not null and p_to is not null then (p_to-p_from)+1 else
                       coalesce((select count(distinct d) from _sup),1) end)::numeric,1);
  v_cap     := (v_hours/ndays) * p_clear_per_hr;                 -- schedule-only async/day
  v_load    := case when v_hours>0 then v_async/(v_hours/ndays) else null end;
  v_stretch := case when p_offshift < 1 then v_cap/(1-p_offshift) else v_cap end;
  v_verdict := case when v_bodies=0 then 'Exposed'
                    when v_cap    >= v_async then 'Covered'
                    when v_stretch>= v_async then 'Stretched'
                    else 'Exposed' end;

  select jsonb_build_object(
    'window',   jsonb_build_object('from',p_from,'to',p_to,'days',ndays),
    'baseline', jsonb_build_object('from',d_from,'to',d_to,'weeks',greatest(p_base_weeks,1)),
    'assumptions', jsonb_build_object('clear_per_hr',p_clear_per_hr,'sync_min',p_sync_min,
                     'offshift_share',p_offshift,'source','calibrated Jun 1-24, TC excluded; overridable'),
    'pool', jsonb_build_object(
       'bodies',v_bodies, 'body_hours',round(v_hours,1),
       'async_per_day',round(v_async), 'sync_per_day',round(v_sync),
       'sched_capacity_per_day',round(v_cap),
       'load_per_body_hour',round(coalesce(v_load,0),1),
       'sync_bodies_needed',round((v_sync * p_sync_min/60.0)/greatest(ndays*(p_hour1-p_hour0+1),1),1),
       'verdict',v_verdict),
    -- staffing grid: bodies on shift by day-of-week x hour x credential
    'by_hour', coalesce((select jsonb_agg(jsonb_build_array(dow,hr,tot,doc,np,pa,ma,gc,ms) order by dow,hr)
       from (select dow,hr,
               count(distinct em) tot,
               count(distinct em) filter (where cred='Doctor') doc,
               count(distinct em) filter (where cred='NP') np,
               count(distinct em) filter (where cred='PA') pa,
               count(distinct em) filter (where cred='MA') ma,
               count(distinct em) filter (where cred='GC') gc,
               count(distinct em) filter (where cred='MS') ms
             from _sup group by dow,hr) g), '[]'::jsonb),
    -- per state: bodies licensed AND scheduled (shared pool -- NOT per-state capacity)
    'by_state', coalesce((select jsonb_agg(jsonb_build_array(
          st, round(a_day,1), round(s_day,1), bodies, hard_gap) order by hard_gap desc, a_day desc nulls last), '[]'::jsonb)
       from (
         select coalesce(d.st,l.st) st,
                coalesce(max(d.a_day),0) a_day, coalesce(max(d.s_day),0) s_day,
                coalesce(max(l.bodies),0) bodies,
                (coalesce(max(d.a_day),0)+coalesce(max(d.s_day),0) > 0 and coalesce(max(l.bodies),0)=0) hard_gap
         from (select st,
                 sum(n) filter (where modality='async')/nullif(max(nd),0) a_day,
                 sum(n) filter (where modality='sync') /nullif(max(nd),0) s_day
               from _dem where st is not null group by st) d
         full join (select ls.st, count(distinct s.rid) bodies
                    from _sup s cross join lateral unnest(s.license_states) ls(st)
                    group by ls.st) l on l.st=d.st
         group by coalesce(d.st,l.st)) z),
    'notes', jsonb_build_object(
       'shared_pool','A clinician licensed in N states is ONE body. Per-state rows show bodies licensed AND scheduled plus hard gaps; capacity verdicts are pool-wide only.',
       'sync','Adding bodies does not move sync attainment in the observed range (misses are structural). Sync shows arrivals and concurrent bodies needed -- no invented band.',
       'offshift','Historically '||round(p_offshift*100)||'% of async is cleared off-shift by unscheduled clinicians. "Stretched" means the schedule does not cover it and discretionary pickup does.')
  ) into out;
  return out;
end $$;
revoke all on function public.staffing_coverage(date,date,int,text[],text[],int,int,int[],numeric,numeric,numeric) from public;
grant execute on function public.staffing_coverage(date,date,int,text[],text[],int,int,int[],numeric,numeric,numeric) to anon, authenticated;
