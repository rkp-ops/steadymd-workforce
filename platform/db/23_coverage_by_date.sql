-- ============================================================================
-- 23_coverage_by_date.sql
-- Date-specific coverage read behind the Capacity "Gaps" view. Applied live to
-- project eeszygextbqglayglvfm as migration  coverage_by_date_rpc.
--
-- coverage_grid (10) answers "what does a TYPICAL week look like" — it collapses
-- every loaded week into a day-of-week × hour composite. That cannot answer the
-- operational Friday question: "for the schedule I just uploaded, where are the
-- gaps THIS weekend?" This RPC keeps the actual calendar date, so the console
-- can lay the uploaded schedule for specific dates against expected demand and
-- rank the thin hours.
--
--   * Window is CALLER-CONTROLLED (p_from/p_to, Central dates); null = no bound.
--     No static window — the client always passes what the user picked.
--   * Same hour expansion + Central-time rules as coverage_grid.
--   * filled  = COUNT(DISTINCT clinician_id) on shift that hour (real people).
--   * unfilled = COUNT(*) of shift-hours that hour from rows with NO clinician —
--     the Arya "Not Assigned" posts. Loaded with clinician_id NULL, they are
--     excluded from filled coverage but surfaced separately: a posted-and-unpicked
--     slot is exactly the gap worth calling out.
--   * range = min/max shift date loaded overall, so the UI can say honestly how
--     far the loaded schedule runs (and show "upload the schedule" past it).
--
-- Output jsonb:
--   { "range": {"min": <date|null>, "max": <date|null>},
--     "rows":  [ [ "YYYY-MM-DD", hr, filled, unfilled ], ... ] }
-- ============================================================================

create or replace function public.coverage_by_date(p_from date default null, p_to date default null)
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
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
    where s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
  ),
  buck as (
    select h::date d, extract(hour from h)::int hr,
           count(distinct clinician_id) filter (where clinician_id is not null) filled,
           count(*) filter (where clinician_id is null) unfilled
    from hrs
    where (p_from is null or h::date >= p_from)
      and (p_to   is null or h::date <= p_to)
    group by 1, 2
  ),
  rng as (
    select min((start_at at time zone 'America/Chicago')::date) mn,
           max((end_at   at time zone 'America/Chicago')::date) mx
    from shift where start_at is not null and end_at is not null
  )
  select jsonb_build_object(
    'range', (select jsonb_build_object('min', mn, 'max', mx) from rng),
    'rows',  coalesce((select jsonb_agg(jsonb_build_array(to_char(d,'YYYY-MM-DD'), hr, filled, unfilled) order by d, hr) from buck), '[]'::jsonb)
  ) into out;
  return out;
end $$;

revoke all on function public.coverage_by_date(date, date) from public;
grant execute on function public.coverage_by_date(date, date) to anon, authenticated;
