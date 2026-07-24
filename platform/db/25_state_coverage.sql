-- ============================================================================
-- 25_state_coverage.sql — state-license coverage vs observed demand
--
-- "Are all 51 states (50 + DC) staffed & covered?" Supply = distinct clinicians
-- on shift in the target window who are LICENSED in a state; demand = observed
-- on-demand SLI arrivals by state over a chosen baseline lookback. A hard gap is
-- a state with demand but zero licensed coverage in the window.
--
-- Licensure source: clinician_roster.license_states (text[]) reached from a shift
-- via the email join (shift.clinician_email_raw = any roster.emails). The
-- normalized clinician_license table is currently unpopulated, so the roster
-- arrays are the source of truth. Supply is LICENSURE-based, not partner-routed:
-- a clinician on a partner-dedicated shift may not actually serve every state
-- they are licensed in — surfaced honestly in the UI, not silently overstated.
--
-- Every param is optional and defaults to the all-loaded / no-filter behavior, so
-- the window is never static — the caller always chooses it.
-- ============================================================================

-- 6-bucket credential classifier (mirrors the console's credClass): the only
-- categories that exist anywhere are Doctor / NP / PA / MA / GC / MS.
create or replace function public.cred_bucket(cred text)
  returns text language sql immutable as $$
  select case
    when c in ('MD','DO')  then 'Doctor'
    when c in ('PA','PAC') then 'PA'
    when c = 'MA' then 'MA'
    when c = 'GC' then 'GC'
    when c = 'MS' then 'MS'
    when c = ''   then '—'
    else 'NP'
  end
  from (select regexp_replace(upper(coalesce(cred,'')), '[^A-Z]', '', 'g') c) x;
$$;
revoke all on function public.cred_bucket(text) from public;
grant execute on function public.cred_bucket(text) to anon, authenticated;

create or replace function public.state_coverage(
    p_from         date    default null,   -- schedule/coverage window (supply)
    p_to           date    default null,
    p_base_weeks   int     default 4,      -- demand baseline lookback, weeks up to newest SLI date
    p_service_line text[]  default null,   -- shift service-line filter (supply)
    p_cred         text[]  default null,   -- credential-bucket filter (supply)
    p_hour0        int     default 0,      -- hour band, Central (both supply-overlap and demand-arrival)
    p_hour1        int     default 23)
  returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare out jsonb; d_to date; d_from date; ndays int;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;

  select max((sli_received at time zone 'America/Chicago')::date) into d_to
    from sli_response where lane = 'on_demand';
  if d_to is null then d_to := current_date; end if;
  d_from := d_to - (greatest(p_base_weeks,1)*7 - 1);
  ndays  := (d_to - d_from) + 1;

  with states(st) as (
    select unnest(array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
      'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC',
      'ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY'])
  ),
  -- SUPPLY: distinct scheduled clinicians (by email) whose shift overlaps the hour band,
  -- within the window and service-line filter; expanded to their licensed states.
  sh as (
    select distinct lower(s.clinician_email_raw) em
    from shift s,
      lateral generate_series(
        date_trunc('hour', s.start_at at time zone 'America/Chicago'),
        (s.end_at at time zone 'America/Chicago') - interval '1 second',
        interval '1 hour') h
    where s.clinician_email_raw is not null and lower(s.clinician_email_raw) <> 'not assigned'
      and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
      and (p_from is null or (s.start_at at time zone 'America/Chicago')::date >= p_from)
      and (p_to   is null or (s.start_at at time zone 'America/Chicago')::date <= p_to)
      and (p_service_line is null or s.service_line = any(p_service_line))
      and extract(hour from h)::int between p_hour0 and p_hour1
  ),
  sup as (
    select ls.st, count(distinct r.id) n
    from sh
    join clinician_roster r on sh.em = any(array(select lower(e) from unnest(r.emails) e))
    cross join lateral unnest(r.license_states) ls(st)
    where (p_cred is null or public.cred_bucket(r.credential) = any(p_cred))
    group by ls.st
  ),
  -- DEMAND: on-demand SLI arrivals by state over the baseline window, in the hour band.
  dem as (
    select nullif(trim(state),'') st, count(*)::numeric c
    from sli_response
    where lane = 'on_demand' and state is not null
      and (sli_received at time zone 'America/Chicago')::date between d_from and d_to
      and extract(hour from sli_received at time zone 'America/Chicago')::int between p_hour0 and p_hour1
    group by 1
  )
  select jsonb_build_object(
    'window',   jsonb_build_object('from', p_from, 'to', p_to),
    'baseline', jsonb_build_object('from', d_from, 'to', d_to, 'weeks', greatest(p_base_weeks,1), 'days', ndays),
    'rows', coalesce(jsonb_agg(jsonb_build_array(
        s.st,
        round(coalesce(d.c,0) / greatest(ndays,1), 1),      -- avg daily demand over the baseline
        coalesce(sup.n, 0),                                  -- licensed clinicians scheduled in the window
        (coalesce(d.c,0) > 0 and coalesce(sup.n,0) = 0)      -- hard gap: demand present, zero licensed coverage
      ) order by (coalesce(d.c,0) > 0 and coalesce(sup.n,0) = 0) desc, coalesce(d.c,0) desc, s.st), '[]'::jsonb)
  ) into out
  from states s
  left join dem d  on d.st  = s.st
  left join sup    on sup.st = s.st;
  return out;
end $$;
revoke all on function public.state_coverage(date,date,int,text[],text[],int,int) from public;
grant execute on function public.state_coverage(date,date,int,text[],text[],int,int) to anon, authenticated;
