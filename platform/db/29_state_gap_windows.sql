-- ============================================================================
-- 29_state_gap_windows.sql - the "when and where will I be uncovered" engine.
--
-- A 51-state x 24-hour grid is unreadable as a list, but the signal is sparse:
-- most states are covered most hours. So this returns only the EXCEPTIONS, and
-- returns them as contiguous WINDOWS rather than loose hours, so the UI can draw
-- them on a time axis instead of enumerating cells.
--
-- Coverage = at least one clinician licensed in that state on shift that hour.
-- Hours are the schedule own clock (UTC extraction), matching whos_on.
-- Windows are ranked by demand at risk, from the trailing 4-week arrival rate,
-- so an uncovered hour in a high-volume state outranks one in a quiet state.
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
  if lo is null then return jsonb_build_object('rows','[]'::jsonb,'no_schedule',true); end if;

  -- demand baseline: last 4 weeks of on-demand arrivals, by state and hour-of-day
  select max((sli_received at time zone 'UTC')::date) into d_to from sli_response where lane='on_demand';
  d_from := coalesce(d_to,current_date) - 27;
  nd := greatest((coalesce(d_to,current_date) - d_from) + 1, 1);

  drop table if exists _cov; drop table if exists _gap; drop table if exists _dm;

  -- states genuinely covered in each hour: at least one licensed body on shift
  create temp table _cov on commit drop as
  select distinct (h)::date d, extract(hour from h)::int hr, ls.st
  from shift s
  join clinician_roster r on lower(s.clinician_email_raw)=any(array(select lower(x) from unnest(r.emails) x))
  cross join lateral unnest(r.license_states) ls(st)
  cross join lateral generate_series(date_trunc('hour', s.start_at at time zone 'UTC'),
        (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') h
  where lower(coalesce(s.clinician_email_raw,''))<>'not assigned'
    and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
    and (h)::date between lo and hi
    and extract(hour from h)::int between p_hour0 and p_hour1
    and (p_service_line is null or s.service_line = any(p_service_line))
    and (p_cred is null or coalesce(public.cred_bucket(r.credential),'-') = any(p_cred));

  create temp table _dm on commit drop as
  select nullif(trim(state),'') st, extract(hour from sli_received at time zone 'UTC')::int hr,
         count(*)::numeric/nd per_day
  from sli_response
  where lane='on_demand' and state is not null
    and (sli_received at time zone 'UTC')::date between d_from and coalesce(d_to,current_date)
  group by 1,2;

  -- every (hour, state) slot the window contains, minus the covered ones
  create temp table _gap on commit drop as
  select g.d, g.hr, s.st,
         ((g.d - date '2026-01-01')*24 + g.hr) hnum,
         coalesce(dm.per_day,0) dem
  from (select generate_series(lo,hi,interval '1 day')::date d) g
  cross join generate_series(p_hour0,p_hour1) hr
  cross join (select unnest(array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA',
    'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR',
    'PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']) st) s
  left join _dm dm on dm.st=s.st and dm.hr=hr
  where not exists (select 1 from _cov c where c.d=g.d and c.hr=hr and c.st=s.st);

  select jsonb_build_object(
    'window', jsonb_build_object('from',lo,'to',hi,'h0',p_hour0,'h1',p_hour1),
    'baseline', jsonb_build_object('from',d_from,'to',d_to),
    'slots_total', (select count(*) from (select generate_series(lo,hi,interval '1 day')) x)*(p_hour1-p_hour0+1)*51,
    'gap_slots', (select count(*) from _gap),
    'states_with_gap', (select count(distinct st) from _gap),
    -- one row per state: its contiguous uncovered windows, worst first
    'rows', coalesce((select jsonb_agg(jsonb_build_array(st, gap_hours, round(dem_at_risk,1), wins)
                              order by dem_at_risk desc, gap_hours desc, st), '[]'::jsonb)
      from (
        select st, sum(len)::int gap_hours, sum(dem_sum) dem_at_risk,
               jsonb_agg(jsonb_build_array(to_char(d0,'YYYY-MM-DD'), h0, to_char(d1,'YYYY-MM-DD'), h1, len, round(dem_sum,1))
                         order by d0, h0) wins
        from (
          select st, count(*)::int len, min(d) d0, min(hr) h0, max(d) d1, max(hr) h1, sum(dem) dem_sum
          from (select *, hnum - row_number() over (partition by st order by hnum) grp from _gap) z
          group by st, grp) w
        group by st) q),
    'worst', (select jsonb_build_array(st, to_char(d0,'YYYY-MM-DD'), h0, h1, len)
              from (select st, min(d) d0, min(hr) h0, max(hr) h1, count(*) len, sum(dem) ds
                    from (select *, hnum - row_number() over (partition by st order by hnum) grp from _gap) z
                    group by st, grp order by ds desc, len desc limit 1) x)
  ) into out;
  return out;
end $$;
revoke all on function public.state_gap_windows(date,date,text[],text[],int,int) from public;
grant execute on function public.state_gap_windows(date,date,text[],text[],int,int) to anon, authenticated;
