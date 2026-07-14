-- ============================================================================
-- 13_demand_grid.sql
-- The demand curve behind the Forecast tab. Applied live to project
-- eeszygextbqglayglvfm as migration  demand_grid_rpc.
--
-- Mirror image of coverage_grid (10): where that counts clinicians ON SHIFT per
-- day-of-week x hour, this counts CONSULTS ARRIVING per day-of-week x hour, both
-- weekly-averaged in Central time and zero-filled across all observed weeks. The
-- console lays the two grids over each other to get load = demand / coverage
-- (consults per on-shift clinician per hour) — the forward-looking pressure map.
--
-- Why rebuilt from live data, not ported: the legacy forecast ran off a
-- hardcoded 57-row arrival matrix (only ~2.4 of its claimed 7 days populated)
-- feeding a logistic model whose scaler parameters didn't match its runtime
-- features. That doesn't scale or hold up. This derives the arrival pattern
-- straight from the consult log, so it sharpens automatically as data grows.
--
-- Lab work is excluded (modality_class <> 'lab') to match every other volume
-- surface in the console — the tracked unit is the chart-review or call, not the
-- lab turnaround. Demand is attribution-independent (we count arrivals by their
-- timestamp, regardless of which clinician they were later credited to), so the
-- consult-attribution artifact does not distort it.
--
-- Output jsonb:
--   { "weeks": <# distinct ISO weeks observed>,
--     "grid":  [ [dow, hr, av, mn, mx], ... ] }   -- dow = isodow 1..7
-- ============================================================================

create or replace function public.demand_grid()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  with ev as (
    select extract(isodow from created_at at time zone 'America/Chicago')::int dow,
           extract(hour   from created_at at time zone 'America/Chicago')::int hr,
           date_trunc('week', created_at at time zone 'America/Chicago')::date wk
    from consult
    where created_at is not null and modality_class <> 'lab'
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

revoke all on function public.demand_grid() from public;
grant execute on function public.demand_grid() to anon, authenticated;
