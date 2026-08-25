-- ============================================================================
-- 30_capacity_filters.sql - make Shifts and Coverage answer a real question
--
-- Standing rule from the operator: "There should never be anything in this
-- console that I can't filter or alter to be exactly what I want or need."
-- shift_summary / coverage_grid / demand_grid took (p_from, p_to) and nothing
-- else, so those two tabs were lumped totals by construction. All three now
-- take the same filter set the rest of the console already uses:
--
--   p_from, p_to, p_service_line[], p_cred[], p_hour0, p_hour1, p_dow[], p_state[]
--
-- Three correctness defects are fixed in passing, all of which made the old
-- numbers wrong rather than merely coarse:
--
-- 1. CLOCK. Shift and consult timestamps are naive wall-clock stored AS UTC.
--    Converting them to America/Chicago shifts them 5-6 hours and invents a
--    peak. Measured on this data: shifts UTC-extracted peak at 12:00 with 86%
--    of hours inside 08-20; consults converted to Chicago peak at 07:00 with
--    only 59% inside 08-20; consults UTC-extracted peak at 12:00 with 75%.
--    coverage_grid was double-shifting supply one way and demand_grid shifting
--    demand the other, so the Coverage heatmap compared two clocks 5-6 hours
--    apart. Everything here extracts at UTC, matching whos_on and
--    state_gap_windows.
--
-- 2. DROPPED SUPPLY. coverage_grid required shift.clinician_id is not null,
--    silently discarding 203 shifts (63 of them real, the rest unfilled posts).
--    Bodies are keyed on lower(clinician_email_raw) like every other engine.
--
-- 3. CREDENTIALS. shift.clinician_cred is null on 20,418 of 20,426 rows, so
--    by_cred was a column of dashes. Credentials come from clinician_roster
--    through the email join and are always the 6 buckets, never raw.
--
-- Silo rule applies as everywhere else: with no explicit p_service_line, only
-- calendars with count_in_coverage are counted, and the excluded list is
-- returned so "All" can name what it left out. Naming a calendar honors that
-- selection exactly.
--
-- Hours are exact overlap, not slot counts: 44% of shifts are fractional
-- (min 0.25h) and 47% start or end mid-hour, so counting hour buckets would
-- overstate. Each bucket contributes its real intersection with the shift.
--
-- Every hour reference is table-qualified. An unqualified `hr` inside a
-- subquery binds to that subquery's own column and silently drops the hour
-- comparison - that shipped once in state_gap_windows and reported a week of
-- gaps as full coverage.
-- ============================================================================

-- ---------------------------------------------------------------- shifts ---
create or replace function public.shift_summary(
    p_from date default null, p_to date default null,
    p_service_line text[] default null, p_cred text[] default null,
    p_hour0 int default 0, p_hour1 int default 23,
    p_dow int[] default null, p_state text[] default null)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;

  drop table if exists _sh;
  create temp table _sh on commit drop as
  select lower(s.clinician_email_raw) em,
         coalesce(s.clinician_name_raw,'(unnamed)') nm,
         coalesce(s.service_line,'(unspecified)') sl,
         coalesce(public.cred_bucket(r.credential),'-') cred,
         (hb.h)::date d,
         extract(hour from hb.h)::int hr,
         extract(isodow from hb.h)::int dow,
         -- exact overlap of this shift with this hour bucket
         extract(epoch from (
           least(s.end_at at time zone 'UTC', hb.h + interval '1 hour')
         - greatest(s.start_at at time zone 'UTC', hb.h)))/3600.0 hrs,
         r.license_states ls
  from shift s
  left join service_line_map m on m.entity = s.service_line
  left join clinician_roster r
    on lower(s.clinician_email_raw) = any(array(select lower(x) from unnest(r.emails) x))
  cross join lateral generate_series(
        date_trunc('hour', s.start_at at time zone 'UTC'),
        (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') hb(h)
  where s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
    and lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
    and (p_from is null or (hb.h)::date >= p_from)
    and (p_to   is null or (hb.h)::date <= p_to)
    and extract(hour from hb.h)::int between p_hour0 and p_hour1
    and (p_dow is null or extract(isodow from hb.h)::int = any(p_dow))
    and (case when p_service_line is not null then s.service_line = any(p_service_line)
              else coalesce(m.count_in_coverage,true) end)
    and (p_cred is null or coalesce(public.cred_bucket(r.credential),'-') = any(p_cred))
    and (p_state is null or r.license_states && p_state);

  select jsonb_build_object(
    'total_hours',  (select round(coalesce(sum(x.hrs),0)::numeric,1) from _sh x),
    'n_shifts',     (select count(distinct (x.em, x.d, x.sl)) from _sh x),
    'n_clinicians', (select count(distinct x.em) from _sh x),
    'range',  (select jsonb_build_object('min',min(x.d)::text,'max',max(x.d)::text) from _sh x),
    'loaded', (select jsonb_build_object('min',min((start_at at time zone 'UTC')::date)::text,
                                         'max',max((start_at at time zone 'UTC')::date)::text) from shift),
    'excluded', case when p_service_line is not null then '[]'::jsonb else
      coalesce((select jsonb_agg(entity order by entity) from service_line_map
                where not count_in_coverage), '[]'::jsonb) end,
    'unfilled', (select jsonb_build_object(
        'hours', coalesce(round(sum(u.hours))::int,0), 'posts', count(*))
      from shift u left join service_line_map um on um.entity = u.service_line
      where lower(coalesce(u.clinician_email_raw,''))='not assigned'
        and (p_from is null or (u.start_at at time zone 'UTC')::date >= p_from)
        and (p_to   is null or (u.start_at at time zone 'UTC')::date <= p_to)
        and (case when p_service_line is not null then u.service_line = any(p_service_line)
                  else coalesce(um.count_in_coverage,true) end)),
    'by_service_line', coalesce((select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select x.sl as name, round(sum(x.hrs)::numeric,1) as hours,
              count(distinct (x.em, x.d)) as shifts, count(distinct x.em) as people
       from _sh x group by x.sl) t), '[]'::jsonb),
    'by_cred', coalesce((select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select x.cred as name, round(sum(x.hrs)::numeric,1) as hours,
              count(distinct (x.em, x.d)) as shifts, count(distinct x.em) as people
       from _sh x group by x.cred) t), '[]'::jsonb),
    'by_hour', coalesce((select jsonb_agg(jsonb_build_array(t.hr, t.hours, t.people) order by t.hr) from (
       select x.hr, round(sum(x.hrs)::numeric,1) hours, count(distinct x.em) people
       from _sh x group by x.hr) t), '[]'::jsonb),
    'by_dow', coalesce((select jsonb_agg(jsonb_build_array(t.dow, t.hours, t.people) order by t.dow) from (
       select x.dow, round(sum(x.hrs)::numeric,1) hours, count(distinct x.em) people
       from _sh x group by x.dow) t), '[]'::jsonb),
    'top_clin', coalesce((select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select x.nm as name, max(x.cred) as cred, round(sum(x.hrs)::numeric,1) as hours,
              count(distinct (x.em, x.d)) as shifts
       from _sh x group by x.nm order by sum(x.hrs) desc limit 25) t), '[]'::jsonb),
    -- every calendar / credential / state present in the CURRENT filter, so the
    -- pickers offer what actually exists rather than a hardcoded list
    'facets', jsonb_build_object(
       'calendars', coalesce((select jsonb_agg(distinct x.sl order by x.sl) from _sh x), '[]'::jsonb),
       'creds',     coalesce((select jsonb_agg(distinct x.cred order by x.cred) from _sh x), '[]'::jsonb))
  ) into out;
  return out;
end $$;
revoke all on function public.shift_summary(date,date,text[],text[],int,int,int[],text[]) from public;
grant execute on function public.shift_summary(date,date,text[],text[],int,int,int[],text[]) to anon, authenticated;

-- -------------------------------------------------------------- coverage ---
create or replace function public.coverage_grid(
    p_from date default null, p_to date default null,
    p_service_line text[] default null, p_cred text[] default null,
    p_hour0 int default 0, p_hour1 int default 23,
    p_dow int[] default null, p_state text[] default null)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;

  drop table if exists _cg;
  create temp table _cg on commit drop as
  select extract(isodow from hb.h)::int dow, extract(hour from hb.h)::int hr,
         date_trunc('week', hb.h)::date wk, lower(s.clinician_email_raw) em
  from shift s
  left join service_line_map m on m.entity = s.service_line
  left join clinician_roster r
    on lower(s.clinician_email_raw) = any(array(select lower(x) from unnest(r.emails) x))
  cross join lateral generate_series(
        date_trunc('hour', s.start_at at time zone 'UTC'),
        (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') hb(h)
  where s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
    and lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
    and (p_from is null or (hb.h)::date >= p_from)
    and (p_to   is null or (hb.h)::date <= p_to)
    and extract(hour from hb.h)::int between p_hour0 and p_hour1
    and (p_dow is null or extract(isodow from hb.h)::int = any(p_dow))
    and (case when p_service_line is not null then s.service_line = any(p_service_line)
              else coalesce(m.count_in_coverage,true) end)
    and (p_cred is null or coalesce(public.cred_bucket(r.credential),'-') = any(p_cred))
    and (p_state is null or r.license_states && p_state);

  with buck as (select c.dow, c.hr, c.wk, count(distinct c.em) n from _cg c group by c.dow, c.hr, c.wk),
       wks  as (select distinct b.wk from buck b),
       gr   as (select d.dow, h.hr from generate_series(1,7) d(dow), generate_series(p_hour0,p_hour1) h(hr)
                where p_dow is null or d.dow = any(p_dow)),
       filled as (select gr.dow, gr.hr, w.wk, coalesce(b.n,0) n
                  from gr cross join wks w
                  left join buck b on b.dow=gr.dow and b.hr=gr.hr and b.wk=w.wk),
       slot as (select f.dow, f.hr, round(avg(f.n),1) av, min(f.n) mn, max(f.n) mx,
                       round(coalesce(stddev_samp(f.n),0),1) sd, count(*) filter (where f.n=0) zw
                from filled f group by f.dow, f.hr)
  select jsonb_build_object(
    'weeks', (select count(*) from wks),
    'bodies', (select count(distinct c.em) from _cg c),
    'excluded', case when p_service_line is not null then '[]'::jsonb else
      coalesce((select jsonb_agg(entity order by entity) from service_line_map
                where not count_in_coverage), '[]'::jsonb) end,
    'grid', coalesce((select jsonb_agg(jsonb_build_array(s.dow,s.hr,s.av,s.mn,s.mx,s.sd,s.zw)
                                       order by s.dow, s.hr) from slot s), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.coverage_grid(date,date,text[],text[],int,int,int[],text[]) from public;
grant execute on function public.coverage_grid(date,date,text[],text[],int,int,int[],text[]) to anon, authenticated;

-- ---------------------------------------------------------------- demand ---
create or replace function public.demand_grid(
    p_from date default null, p_to date default null,
    p_service_line text[] default null, p_cred text[] default null,
    p_hour0 int default 0, p_hour1 int default 23,
    p_dow int[] default null, p_state text[] default null)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  -- p_cred is accepted for signature symmetry with the supply side; a consult
  -- carries no credential requirement, so it is deliberately not applied.

  drop table if exists _dg;
  create temp table _dg on commit drop as
  select extract(isodow from sr.sli_received at time zone 'UTC')::int dow,
         extract(hour   from sr.sli_received at time zone 'UTC')::int hr,
         date_trunc('week', sr.sli_received at time zone 'UTC')::date wk
  from sli_response sr
  where sr.lane = 'on_demand' and sr.sli_received is not null
    and (p_from is null or (sr.sli_received at time zone 'UTC')::date >= p_from)
    and (p_to   is null or (sr.sli_received at time zone 'UTC')::date <= p_to)
    and extract(hour from sr.sli_received at time zone 'UTC')::int between p_hour0 and p_hour1
    and (p_dow is null or extract(isodow from sr.sli_received at time zone 'UTC')::int = any(p_dow))
    and (p_state is null or nullif(trim(sr.state),'') = any(p_state))
    -- siloed partners never inflate pooled demand unless named explicitly
    and not exists (select 1 from service_line_map m
                    where m.demand_match is not null and not m.count_in_sla
                      and sr.partner ilike '%'||m.demand_match||'%'
                      and (p_service_line is null or not (m.entity = any(p_service_line))))
    and (p_service_line is null or exists (
          select 1 from service_line_map m
          where m.entity = any(p_service_line)
            and (m.demand_match is null or sr.partner ilike '%'||m.demand_match||'%')));

  with buck as (select e.dow, e.hr, e.wk, count(*) n from _dg e group by e.dow, e.hr, e.wk),
       wks  as (select distinct b.wk from buck b),
       gr   as (select d.dow, h.hr from generate_series(1,7) d(dow), generate_series(p_hour0,p_hour1) h(hr)
                where p_dow is null or d.dow = any(p_dow)),
       filled as (select gr.dow, gr.hr, w.wk, coalesce(b.n,0) n
                  from gr cross join wks w
                  left join buck b on b.dow=gr.dow and b.hr=gr.hr and b.wk=w.wk),
       slot as (select f.dow, f.hr, round(avg(f.n),1) av, min(f.n) mn, max(f.n) mx
                from filled f group by f.dow, f.hr)
  select jsonb_build_object(
    'weeks', (select count(*) from wks),
    'arrivals', (select count(*) from _dg),
    'grid', coalesce((select jsonb_agg(jsonb_build_array(s.dow,s.hr,s.av,s.mn,s.mx)
                                       order by s.dow, s.hr) from slot s), '[]'::jsonb)
  ) into out;
  return out;
end $$;
revoke all on function public.demand_grid(date,date,text[],text[],int,int,int[],text[]) from public;
grant execute on function public.demand_grid(date,date,text[],text[],int,int,int[],text[]) to anon, authenticated;
