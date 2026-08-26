-- ============================================================================
-- 33_coverage_feed.sql - the raw feed behind the client-side coverage console
--
-- The Gaps / Who's on / State coverage tabs recompute instantly as the operator
-- changes the date window, the hour range, the calendars, or marks a clinician
-- out (a hypothetical, never persisted). Round-tripping the server on every such
-- change is both slow and impossible for the mark-out overrides, so those three
-- tabs share ONE client-side engine fed by this single feed, pulled once.
--
-- Returns, for the loaded schedule window:
--   roster  - one row PER SHIFT BLOCK on a coverage calendar:
--             [name, cred_bucket, sl_abbrev, start_iso, end_iso, "STATES,CSV"]
--             (UTC wall-clock, the schedule's own clock, matching whos_on /
--             state_gap_windows). License states come from the flattened roster.
--   demand  - trailing 4-week on-demand arrival baseline, PER STATE x HOUR,
--             split sync vs async: [state, hour, async_per_day, sync_per_day].
--             Hour is the arrival's own UTC clock. Sync = video_chat / urgent
--             (the whatif-substrate rule), async = messaging/chart/other; lab is
--             excluded. Siloed partners (count_in_sla=false: Transcarent, Sanofi,
--             ixlayer, MA P2, Thirty Madison, Rezilient) never enter the pool.
--   calendars - the coverage calendars present in the window, with a short
--             abbrev and a friendly name, for the checkable picker.
--
-- SILO RULE: supply is coverage calendars only (count_in_coverage=true); demand
-- excludes count_in_sla=false partners. Counting the siloed calendars understated
-- exposure by more than half - they are a separate population, never the pool.
-- ============================================================================
create or replace function public.coverage_feed(
    p_from date default null, p_to date default null)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb; lo date; hi date; d_to date; d_from date; nd int;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  select coalesce(p_from, min((start_at at time zone 'UTC')::date)),
         coalesce(p_to,   max((start_at at time zone 'UTC')::date)) into lo, hi from shift;
  if lo is null then
    return jsonb_build_object('roster','[]'::jsonb,'demand','[]'::jsonb,'calendars','[]'::jsonb,'no_schedule',true);
  end if;

  select max((sli_received at time zone 'UTC')::date) into d_to from sli_response where lane='on_demand';
  d_from := coalesce(d_to,current_date) - 27;
  nd := greatest((coalesce(d_to,current_date) - d_from) + 1, 1);

  -- one row per lowercased email -> cred bucket + license states. The correlated
  -- form of this join is the 44,896ms nested loop; do not inline it back.
  drop table if exists _cr;
  create temp table _cr on commit drop as
  select distinct on (lower(e)) lower(e) em,
         coalesce(public.cred_bucket(r.credential),'-') cred, r.license_states ls
  from clinician_roster r cross join lateral unnest(r.emails) e
  order by lower(e), r.id;
  create index on _cr(em);

  -- Siloed partners, resolved ONCE over the small distinct-partner set rather
  -- than a correlated ilike per demand row. The per-row anti-join over ~86k
  -- baseline rows was the cost; this makes demand a hash anti-join.
  drop table if exists _silo;
  create temp table _silo on commit drop as
  select distinct p.partner from (select distinct partner from sli_response where lane='on_demand' and partner is not null) p
  where exists (select 1 from service_line_map m
                where m.demand_match is not null and not m.count_in_sla
                  and p.partner ilike '%'||m.demand_match||'%');
  create index on _silo(partner);

  select jsonb_build_object(
    'window',   jsonb_build_object('from', lo, 'to', hi),
    'loaded',   (select jsonb_build_object('min',min((start_at at time zone 'UTC')::date),
                                           'max',max((start_at at time zone 'UTC')::date)) from shift),
    'baseline', jsonb_build_object('from', d_from, 'to', d_to),

    -- coverage calendars present in the window: [entity, abbrev, friendly_name, bodies]
    'calendars', coalesce((select jsonb_agg(jsonb_build_array(c.entity, c.abbrev, c.name, c.bodies)
                                            order by c.name)
       from (select m.entity,
                    coalesce(nullif(m.abbrev,''), left(m.entity,10)) abbrev,
                    regexp_replace(m.entity,'\s+(Service Line|Program Schedule|Schedule|Program)$','') name,
                    count(distinct lower(s.clinician_email_raw)) bodies
             from shift s
             join service_line_map m on m.entity = s.service_line and m.count_in_coverage
             where lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
               and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
               and (s.end_at   at time zone 'UTC')::date >= lo
               and (s.start_at at time zone 'UTC')::date <= hi
             group by m.entity, m.abbrev) c), '[]'::jsonb),

    -- roster: one row per shift block on a coverage calendar overlapping [lo,hi]
    'roster', coalesce((select jsonb_agg(jsonb_build_array(
            coalesce(nullif(s.clinician_name_raw,''),'(unnamed)'),
            coalesce(rt.cred,'-'),
            coalesce(nullif(m.abbrev,''), left(m.entity,10)),
            to_char(s.start_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI'),
            to_char(s.end_at   at time zone 'UTC','YYYY-MM-DD"T"HH24:MI'),
            array_to_string(coalesce(rt.ls,'{}'), ','))
            order by s.start_at, s.clinician_name_raw)
       from shift s
       join service_line_map m on m.entity = s.service_line and m.count_in_coverage
       left join _cr rt on rt.em = lower(s.clinician_email_raw)
       where lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
         and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
         and (s.end_at   at time zone 'UTC')::date >= lo
         and (s.start_at at time zone 'UTC')::date <= hi), '[]'::jsonb),

    -- demand: [state, hour, async_per_day, sync_per_day], trailing 4wk, siloed out
    'demand', coalesce((select jsonb_agg(jsonb_build_array(z.st, z.hr, z.apd, z.spd)
                                         order by z.st, z.hr)
       from (select st, hr,
               round(count(*) filter (where not syn)::numeric / nd, 3) apd,
               round(count(*) filter (where syn)::numeric / nd, 3)     spd
             from (select nullif(trim(sr.state),'') st,
                          extract(hour from sr.sli_received at time zone 'UTC')::int hr,
                          -- sync = live video / urgent (the whatif-substrate rule); lab excluded
                          (case when sr.consult_type ilike '%lab%' then null
                                when sr.consult_type in ('video_chat','urgent-care') then true
                                else false end) syn
                   from sli_response sr
                   where sr.lane = 'on_demand' and sr.state is not null
                     and (sr.sli_received at time zone 'UTC')::date between d_from and coalesce(d_to,current_date)
                     and not exists (select 1 from _silo z where z.partner = sr.partner)) q
             where q.st is not null and q.syn is not null
             group by st, hr) z), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.coverage_feed(date,date) from public;
grant execute on function public.coverage_feed(date,date) to anon, authenticated;
