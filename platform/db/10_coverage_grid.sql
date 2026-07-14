-- ============================================================================
-- 10_coverage_grid.sql
-- The Coverage & reliability tab's RPC. Applied live to project
-- eeszygextbqglayglvfm as migration  coverage_grid_rpc.
--
-- Answers "who is actually on shift, by day-of-week and hour, and how much does
-- that coverage wobble week to week." One gated reader, computed server-side
-- from the shift fact table so the console just paints the grid.
--
-- Design notes:
--   * Shifts are expanded to their Central-time wall-clock hours with
--     generate_series, so a shift spanning 09:00–17:00 CT contributes to eight
--     hourly buckets. Central time (America/Chicago) is the ops clock; DST is
--     handled by doing the truncation in that zone.
--   * A slot's headcount is COUNT(DISTINCT clinician_id) — two shifts from the
--     same person in one hour count once.
--   * Reliability needs the zeros. We cross-join the full 7×24 grid against
--     every observed week and LEFT JOIN the actual buckets, so a day-hour that
--     had nobody on in some week is a real 0 in that week's sample — not a
--     missing row. Without this, stddev and the zero-week count would only see
--     the weeks that happened to have coverage and would read far too rosy.
--   * Returns raw components per slot (avg, min, max, sample stddev, #weeks at
--     zero); the client derives the heatmap hue, the "thinnest daytime" list,
--     and the "least reliable" list (sd/av high, or any zero week).
--
-- Output jsonb:
--   { "weeks": <# distinct ISO weeks observed>,
--     "grid":  [ [dow, hr, av, mn, mx, sd, zw], ... ] }   -- dow = isodow 1..7
-- ============================================================================

create or replace function public.coverage_grid()
  returns jsonb
  language plpgsql
  stable security definer
  set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  with hrs as (
    -- one row per (clinician, wall-clock hour) the shift covers, in Central time
    select s.clinician_id,
      generate_series(
        date_trunc('hour', s.start_at at time zone 'America/Chicago'),
        (s.end_at at time zone 'America/Chicago') - interval '1 second',
        interval '1 hour') as h
    from shift s
    where s.clinician_id is not null and s.start_at is not null
      and s.end_at is not null and s.end_at > s.start_at
  ),
  buck as (
    -- distinct clinicians on shift, per day-of-week × hour × ISO week
    select extract(isodow from h)::int dow, extract(hour from h)::int hr,
           date_trunc('week', h)::date wk, count(distinct clinician_id) n
    from hrs group by 1,2,3
  ),
  wks as (select distinct wk from buck),
  gr as (select d.dow, h.hr from generate_series(1,7) d(dow), generate_series(0,23) h(hr)),
  filled as (
    -- every slot × every observed week, zero-filled where nobody was on
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
    'grid', coalesce(jsonb_agg(jsonb_build_array(dow,hr,av,mn,mx,sd,zw) order by dow,hr), '[]'::jsonb)
  ) into out from slot;
  return out;
end $$;

-- Console reader: no direct table access, gated inside the body, exposed to the
-- browser roles exactly like the other console RPCs.
revoke all on function public.coverage_grid() from public;
grant execute on function public.coverage_grid() to anon, authenticated;
