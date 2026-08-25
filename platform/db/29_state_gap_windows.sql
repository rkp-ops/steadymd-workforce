-- ============================================================================
-- 29_state_gap_windows.sql - when and where will we be uncovered
--
-- The signal is sparse: most states are covered most hours. So this returns
-- only the EXCEPTIONS, and returns them as contiguous WINDOWS rather than loose
-- hours - about 30 of them for a week.
--
-- Thirty discrete events is a TABLE, not a chart. An earlier UI drew these as
-- 168 hour-columns across ~1000px, which made a one-hour gap a six-pixel mark
-- and forced a hover to read which day it was, what hour it started, how long
-- it ran, or who was working. `windows` is therefore returned FLAT and
-- worst-first so the console can print each one as a row of plain text.
--
-- Each window also carries who IS on shift during it and their credential mix.
-- That separates a licensure problem ("6 people working, none licensed in NC")
-- from a staffing problem ("nobody is on at all") - a different fix each time.
--
-- Coverage = at least one clinician licensed in that state on shift that hour,
-- derived from the on-shift set rather than expanded a second time.
-- Hours are the schedule's own clock (UTC extraction), matching whos_on.
-- Windows are ranked by demand at risk from the trailing 4-week arrival rate.
--
-- SILO RULE: with no explicit calendar selection, supply and demand both run
-- through service_line_map. Calendars with count_in_coverage=false are NOT
-- coverage for the on-demand pool and must never mask a gap (Transcarent,
-- Thirty Madison, MA P2 Calls, Sanofi/ixlayer, Rezilient). Counting them
-- understated exposure by more than half.
-- ============================================================================
create or replace function public.state_gap_windows(
    p_from date default null, p_to date default null,
    p_service_line text[] default null, p_cred text[] default null,
    p_hour0 int default 0, p_hour1 int default 23)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb; lo date; hi date; d_to date; d_from date; nd int;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  select coalesce(p_from, min((start_at at time zone 'UTC')::date)),
         coalesce(p_to,   max((start_at at time zone 'UTC')::date)) into lo, hi from shift;
  if lo is null then return jsonb_build_object('windows','[]'::jsonb,'no_schedule',true); end if;

  select max((sli_received at time zone 'UTC')::date) into d_to from sli_response where lane='on_demand';
  d_from := coalesce(d_to,current_date) - 27;
  nd := greatest((coalesce(d_to,current_date) - d_from) + 1, 1);

  drop table if exists _gr; drop table if exists _oh; drop table if exists _cov;
  drop table if exists _gap; drop table if exists _dm;

  -- one row per lowercased email. The correlated form of this join
  --   lower(s.clinician_email_raw) = any(array(select lower(x) from unnest(r.emails) x))
  -- forces a nested loop re-running the unnest per (shift x roster) pair and
  -- cost 4,263ms for a seven-day window. Do not inline it back.
  create temp table _gr on commit drop as
  select distinct on (lower(e)) lower(e) em,
         coalesce(public.cred_bucket(r.credential),'-') cred, r.license_states ls
  from clinician_roster r cross join lateral unnest(r.emails) e
  order by lower(e), r.id;
  create index on _gr(em);

  -- THE single hour expansion. Everyone on shift each hour. Expanding a second
  -- time to build coverage separately cost 5,416ms; coverage is derivable from
  -- this set, since a state is covered iff somebody on then is licensed for it.
  create temp table _oh on commit drop as
  select distinct (((h)::date - date '2026-01-01')*24 + extract(hour from h)::int) hnum,
         (h)::date d, extract(hour from h)::int hr,
         lower(s.clinician_email_raw) em, coalesce(rt.cred,'-') cred
  from shift s
  left join service_line_map m on m.entity = s.service_line
  left join _gr rt on rt.em = lower(s.clinician_email_raw)
  cross join lateral generate_series(date_trunc('hour', s.start_at at time zone 'UTC'),
        (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') h
  where lower(coalesce(s.clinician_email_raw,''))<>'not assigned'
    and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
    and (h)::date between lo and hi
    and extract(hour from h)::int between p_hour0 and p_hour1
    and (case when p_service_line is not null then s.service_line = any(p_service_line)
              else coalesce(m.count_in_coverage,true) end)
    and (p_cred is null or coalesce(rt.cred,'-') = any(p_cred));
  create index on _oh(hnum);

  create temp table _cov on commit drop as
  select distinct o.d, o.hr, ls.st
  from _oh o join _gr rt on rt.em = o.em
  cross join lateral unnest(rt.ls) ls(st);
  create index on _cov(d, hr, st);

  create temp table _dm on commit drop as
  select nullif(trim(sr.state),'') st, extract(hour from sr.sli_received at time zone 'UTC')::int hr,
         count(*)::numeric/nd per_day
  from sli_response sr
  where sr.lane='on_demand' and sr.state is not null
    and (sr.sli_received at time zone 'UTC')::date between d_from and coalesce(d_to,current_date)
    and not exists (select 1 from service_line_map m
                    where m.demand_match is not null and not m.count_in_sla
                      and sr.partner ilike '%'||m.demand_match||'%'
                      and (p_service_line is null or not (m.entity = any(p_service_line))))
    and (p_service_line is null or exists (
          select 1 from service_line_map m
          where m.entity = any(p_service_line)
            and (m.demand_match is null or sr.partner ilike '%'||m.demand_match||'%')))
  group by 1,2;

  -- EVERY hour reference is table-qualified on purpose. An unqualified `hr`
  -- inside the NOT EXISTS binds to the subquery's own _cov.hr, so `c.hr = hr`
  -- degrades to `c.hr = c.hr` and the hour dimension drops out entirely. That
  -- shipped once and reported a week with 55 uncovered state-hours as fully
  -- covered. Do not un-qualify.
  create temp table _gap on commit drop as
  select g.d, hs.hr, s.st,
         ((g.d - date '2026-01-01')*24 + hs.hr) hnum,
         coalesce(dm.per_day,0) dem
  from (select generate_series(lo,hi,interval '1 day')::date d) g
  cross join (select generate_series(p_hour0,p_hour1) hr) hs
  cross join (select unnest(array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA',
    'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR',
    'PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']) st) s
  left join _dm dm on dm.st=s.st and dm.hr=hs.hr
  where not exists (select 1 from _cov c where c.d=g.d and c.hr=hs.hr and c.st=s.st);

  with w as (
    -- bounds from hnum, never min(hr)/max(hr): a run crossing midnight would
    -- otherwise report min 0 / max 23 and render as a full inverted day
    select st, count(*)::int len, min(hnum) h0n, max(hnum) h1n, sum(dem) dem_sum
    from (select *, hnum - row_number() over (partition by st order by hnum) grp from _gap) z
    group by st, grp),
  wo as (
    select w.*,
      (select count(distinct x.em) from _oh x where x.hnum between w.h0n and w.h1n) n_on,
      (select coalesce(jsonb_agg(jsonb_build_array(t.cred,t.n) order by t.n desc, t.cred),'[]'::jsonb)
       from (select x.cred, count(distinct x.em) n from _oh x
             where x.hnum between w.h0n and w.h1n group by x.cred) t) mix
    from w)
  select jsonb_build_object(
    'window', jsonb_build_object('from',lo,'to',hi,'h0',p_hour0,'h1',p_hour1),
    'baseline', jsonb_build_object('from',d_from,'to',d_to),
    'slots_total', (select count(*) from (select generate_series(lo,hi,interval '1 day')) x)*(p_hour1-p_hour0+1)*51,
    'gap_slots', (select count(*) from _gap),
    'states_with_gap', (select count(distinct st) from _gap),
    'excluded', case when p_service_line is not null then '[]'::jsonb else
      coalesce((select jsonb_agg(entity order by entity) from service_line_map
                where not count_in_coverage), '[]'::jsonb) end,
    'unfilled', (select jsonb_build_object(
        'hours', coalesce(round(sum(u.hours))::int,0), 'posts', count(*))
      from shift u
      left join service_line_map um on um.entity = u.service_line
      where lower(coalesce(u.clinician_email_raw,''))='not assigned'
        and (u.start_at at time zone 'UTC')::date between lo and hi
        and (case when p_service_line is not null then u.service_line = any(p_service_line)
                  else coalesce(um.count_in_coverage,true) end)),
    -- which hours of the day gaps land in, as DATA so the UI can say it in
    -- words rather than draw a chart nobody can read
    'by_hour', coalesce((select jsonb_agg(jsonb_build_array(t.hr,t.n) order by t.hr)
                         from (select g.hr, count(*) n from _gap g group by g.hr) t), '[]'::jsonb),
    -- FLAT, worst first. One row of the table per element:
    -- [state, start_date, start_hr, end_date, end_hr_exclusive, hours,
    --  arrivals_per_day, n_on_shift, [[credential, n], ...]]
    'windows', coalesce((select jsonb_agg(jsonb_build_array(
          wo.st,
          to_char(date '2026-01-01' + (wo.h0n/24), 'YYYY-MM-DD'), (wo.h0n%24),
          to_char(date '2026-01-01' + (wo.h1n/24), 'YYYY-MM-DD'), (wo.h1n%24)+1,
          wo.len, round(wo.dem_sum,1), wo.n_on, wo.mix)
          order by wo.dem_sum desc, wo.len desc, wo.st, wo.h0n) from wo), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.state_gap_windows(date,date,text[],text[],int,int) from public;
grant execute on function public.state_gap_windows(date,date,text[],text[],int,int) to anon, authenticated;
