-- ============================================================================
-- 24_windowed_summaries.sql
-- No-static-windows pass, server side. Applied live to project
-- eeszygextbqglayglvfm as migration  windowed_summaries.
--
-- Every summary RPC behind Consults / Shifts / Coverage / Forecast / Incentives
-- aggregated ALL loaded rows with no date parameters — which is exactly why
-- those tabs' windows were not editable. This drops the zero-arg versions and
-- recreates each with (p_from date default null, p_to date default null):
--   * no args  → identical behavior to before (all loaded), so existing calls
--     keep working;
--   * args     → the aggregation itself is windowed server-side.
-- Each summary also returns 'loaded' = the full on-disk range regardless of
-- window, so the client can always say how far the loaded data runs.
--
-- Date conventions per fact (matching how each tab already displays ranges):
--   shift      → Central wall-clock date of start_at
--   incentive  → launched_at::date
--   consult    → created_at::date
--   coverage / demand grids → Central date of the expanded hour / arrival
-- ============================================================================

-- ---------- shift_summary ----------
drop function if exists public.shift_summary();
create or replace function public.shift_summary(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  return (with s as (
    select * from public.shift
    where (p_from is null or (start_at at time zone 'America/Chicago')::date >= p_from)
      and (p_to   is null or (start_at at time zone 'America/Chicago')::date <= p_to))
  select jsonb_build_object(
    'total_hours', (select round(sum(hours)::numeric,1) from s),
    'n_shifts', (select count(*) from s),
    'n_clinicians', (select count(distinct clinician_email_raw) from s),
    'range', (select jsonb_build_object('min',min(start_at)::date::text,'max',max(start_at)::date::text) from s),
    'loaded', (select jsonb_build_object('min',min(start_at)::date::text,'max',max(start_at)::date::text) from public.shift),
    'by_service_line', (select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select coalesce(service_line,'(unspecified)') as name, round(sum(hours)::numeric,1) as hours, count(*) as shifts
       from s group by service_line) t),
    'by_cred', (select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select coalesce(clinician_cred,'—') as name, round(sum(hours)::numeric,1) as hours, count(*) as shifts
       from s group by clinician_cred) t),
    'top_clin', (select jsonb_agg(to_jsonb(t) order by t.hours desc) from (
       select clinician_name_raw as name, coalesce(clinician_cred,'—') as cred, round(sum(hours)::numeric,1) as hours, count(*) as shifts
       from s where clinician_name_raw is not null group by clinician_name_raw, clinician_cred order by sum(hours) desc limit 15) t)
  ));
end; $$;
revoke all on function public.shift_summary(date,date) from public;
grant execute on function public.shift_summary(date,date) to anon, authenticated;

-- ---------- incentive_summary ----------
drop function if exists public.incentive_summary();
create or replace function public.incentive_summary(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  return (with i as (
    select * from public.incentive
    where (p_from is null or launched_at::date >= p_from)
      and (p_to   is null or launched_at::date <= p_to))
  select jsonb_build_object(
    'total_usd', (select round((sum(amount_cents)/100.0)::numeric,2) from i),
    'n_items', (select count(*) from i),
    'n_clinicians', (select count(distinct clinician_email_raw) from i),
    'range', (select jsonb_build_object('min',min(launched_at)::date::text,'max',max(launched_at)::date::text) from i),
    'loaded', (select jsonb_build_object('min',min(launched_at)::date::text,'max',max(launched_at)::date::text) from public.incentive),
    'by_license', (select jsonb_agg(to_jsonb(t) order by t.usd desc) from (
       select coalesce(license_type,'—') as name, round((sum(amount_cents)/100.0)::numeric,2) as usd, count(*) as n from i group by license_type) t),
    'by_partner', (select jsonb_agg(to_jsonb(t) order by t.usd desc) from (
       select coalesce(partner,'—') as name, round((sum(amount_cents)/100.0)::numeric,2) as usd, count(*) as n from i group by partner) t),
    'by_program', (select jsonb_agg(to_jsonb(t) order by t.usd desc) from (
       select coalesce(program,'—') as name, round((sum(amount_cents)/100.0)::numeric,2) as usd, count(*) as n from i group by program order by sum(amount_cents) desc limit 12) t),
    'by_incentive', (select jsonb_agg(to_jsonb(t) order by t.usd desc) from (
       select coalesce(incentive_name,'—') as name, round((sum(amount_cents)/100.0)::numeric,2) as usd, count(*) as n from i group by incentive_name) t),
    'top_earners', (select jsonb_agg(to_jsonb(t) order by t.usd desc) from (
       select clinician_name_raw as name, coalesce(license_type,'—') as license, round((sum(amount_cents)/100.0)::numeric,2) as usd, count(*) as n
       from i where clinician_name_raw is not null group by clinician_name_raw, license_type order by sum(amount_cents) desc limit 15) t)
  ));
end; $$;
revoke all on function public.incentive_summary(date,date) from public;
grant execute on function public.incentive_summary(date,date) to anon, authenticated;

-- ---------- coverage_grid ----------
drop function if exists public.coverage_grid();
create or replace function public.coverage_grid(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  with hrs as (
    select s.clinician_id,
      generate_series(
        date_trunc('hour', s.start_at at time zone 'America/Chicago'),
        (s.end_at at time zone 'America/Chicago') - interval '1 second',
        interval '1 hour') as h
    from shift s
    where s.clinician_id is not null and s.start_at is not null
      and s.end_at is not null and s.end_at > s.start_at
  ),
  fhrs as (select * from hrs where (p_from is null or h::date >= p_from) and (p_to is null or h::date <= p_to)),
  buck as (
    select extract(isodow from h)::int dow, extract(hour from h)::int hr,
           date_trunc('week', h)::date wk, count(distinct clinician_id) n
    from fhrs group by 1,2,3
  ),
  wks as (select distinct wk from buck),
  gr as (select d.dow, h.hr from generate_series(1,7) d(dow), generate_series(0,23) h(hr)),
  filled as (
    select gr.dow, gr.hr, w.wk, coalesce(b.n,0) n
    from gr cross join wks w
    left join buck b on b.dow = gr.dow and b.hr = gr.hr and b.wk = w.wk
  ),
  slot as (
    select dow, hr, round(avg(n),1) av, min(n) mn, max(n) mx,
           round(coalesce(stddev_samp(n),0),1) sd, count(*) filter (where n=0) zw
    from filled group by dow, hr
  )
  select jsonb_build_object(
    'weeks', (select count(*) from wks),
    'grid', coalesce(jsonb_agg(jsonb_build_array(dow, hr, av, mn, mx, sd, zw) order by dow, hr), '[]'::jsonb)
  ) into out from slot;
  return out;
end $$;
revoke all on function public.coverage_grid(date,date) from public;
grant execute on function public.coverage_grid(date,date) to anon, authenticated;

-- ---------- demand_grid ----------
drop function if exists public.demand_grid();
create or replace function public.demand_grid(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  with ev as (
    select extract(isodow from created_at at time zone 'America/Chicago')::int dow,
           extract(hour   from created_at at time zone 'America/Chicago')::int hr,
           date_trunc('week', created_at at time zone 'America/Chicago')::date wk
    from consult
    where created_at is not null and modality_class <> 'lab'
      and (p_from is null or (created_at at time zone 'America/Chicago')::date >= p_from)
      and (p_to   is null or (created_at at time zone 'America/Chicago')::date <= p_to)
  ),
  buck as (select dow, hr, wk, count(*) n from ev group by 1,2,3),
  wks  as (select distinct wk from buck),
  gr   as (select d.dow, h.hr from generate_series(1,7) d(dow), generate_series(0,23) h(hr)),
  filled as (
    select gr.dow, gr.hr, w.wk, coalesce(b.n,0) n
    from gr cross join wks w
    left join buck b on b.dow = gr.dow and b.hr = gr.hr and b.wk = w.wk
  ),
  slot as (select dow, hr, round(avg(n),1) av, min(n) mn, max(n) mx from filled group by dow, hr)
  select jsonb_build_object(
    'weeks', (select count(*) from wks),
    'grid', coalesce(jsonb_agg(jsonb_build_array(dow, hr, av, mn, mx) order by dow, hr), '[]'::jsonb)
  ) into out from slot;
  return out;
end $$;
revoke all on function public.demand_grid(date,date) from public;
grant execute on function public.demand_grid(date,date) to anon, authenticated;

-- ---------- consult_summary ----------
drop function if exists public.consult_summary();
drop function if exists public._consult_summary_impl();
create or replace function public._consult_summary_impl(p_from date default null, p_to date default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with nl as (
    select * from public.consult where modality_class <> 'lab'
      and (p_from is null or created_at::date >= p_from)
      and (p_to   is null or created_at::date <= p_to))
  select jsonb_build_object(
    'total', (select count(*) from nl),
    'lab_excluded', (select count(*) from public.consult where modality_class='lab'),
    'worked_pct', (select round((100.0*count(*) filter (where n_worked_touches>0)/nullif(count(*),0))::numeric,1) from nl),
    'clinicians', (select count(distinct clinician_guid) from nl),
    'touches', (select sum(n_touches) from nl),
    'range', (select jsonb_build_object('min',min(created_at)::date::text,'max',max(final_status_at)::date::text) from nl),
    'loaded', (select jsonb_build_object('min',min(created_at)::date::text,'max',max(final_status_at)::date::text) from public.consult where modality_class <> 'lab'),
    'by_modality', (select jsonb_agg(to_jsonb(t) order by t.n desc) from (
       select modality_class as key,
         case modality_class when 'messaging' then 'Messaging' when 'sync_video' then 'Synchronous video'
           when 'sync_phone' then 'Critical-value call' else 'Other' end as label,
         case modality_class when 'messaging' then 'async' when 'sync_video' then 'sync'
           when 'sync_phone' then 'sync' else 'other' end as kind,
         count(*) as n,
         round((100.0*count(*) filter (where n_worked_touches>0)/count(*))::numeric,1) as worked,
         round((percentile_cont(0.5) within group (order by handle_seconds) filter (where handle_seconds>0)/60.0)::numeric,1) as p50
       from nl group by modality_class) t),
    'by_type', (select jsonb_agg(to_jsonb(t) order by (t.name='chart_addendum'), t.n desc) from (
       select consult_type as name, modality_class as modality, count(*) as n,
         round((100.0*count(*) filter (where n_worked_touches>0)/count(*))::numeric,1) as worked,
         count(*) filter (where handle_seconds>0) as wh,
         round((percentile_cont(0.5) within group (order by handle_seconds) filter (where handle_seconds>0)/60.0)::numeric,1) as p50
       from nl group by consult_type, modality_class) t),
    'top_clin', (select jsonb_agg(to_jsonb(t) order by t.n desc) from (
       select clinician_name_raw as name, count(*) as n, round((100.0*count(*)/nullif((select count(*) from nl),0))::numeric,1) as pct
       from nl group by clinician_name_raw order by count(*) desc limit 12) t),
    'by_partner', (select jsonb_agg(to_jsonb(t) order by t.n desc) from (
       select partner as name, count(*) as n from nl group by partner order by count(*) desc limit 20) t)
  );
$$;
create or replace function public.consult_summary(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  return public._consult_summary_impl(p_from, p_to);
end; $$;
revoke all on function public._consult_summary_impl(date,date) from public;
revoke all on function public.consult_summary(date,date) from public;
grant execute on function public.consult_summary(date,date) to anon, authenticated;
