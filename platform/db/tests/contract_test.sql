-- ============================================================================
-- contract_test.sql - does the DEPLOYED database still answer what the console
-- reads, and fast enough for the paths it is called on?
--
-- Why this exists: the repo SQL files drifted from the deployed functions three
-- times in one session (a missing `unfilled` block, a missing `p_clinician`
-- predicate, a missing `loaded` key). Each time the file looked right and the
-- database was different. Comparing file text to prosrc is fragile - comments
-- differ legitimately - so this asserts BEHAVIOUR instead: the key set each
-- function returns, and the cost of the calls the console actually makes.
--
-- The performance assertions are not cosmetic. shift_summary and coverage_grid
-- are called with NO date bounds on sign-in. A roster join written as a
-- correlated unnest made that path take 60s+ and it shipped live.
-- ============================================================================
do $$
declare j jsonb; t0 timestamptz; ms numeric; missing text;
  function_keys constant jsonb := jsonb_build_object(
    'shift_summary', jsonb_build_array('total_hours','n_shifts','n_clinicians','range','loaded',
                                       'excluded','unfilled','by_service_line','by_cred','top_clin','facets'),
    'coverage_grid', jsonb_build_array('weeks','bodies','excluded','grid'),
    'demand_grid',   jsonb_build_array('weeks','arrivals','loaded','source','grid'),
    'state_gap_windows', jsonb_build_array('window','baseline','slots_total','gap_slots',
                                           'states_with_gap','excluded','unfilled','by_hour','windows'),
    'whos_on', jsonb_build_array('window','loaded','calendars','rows','peak','total_bodies'));
  fname text; want text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select auth_uid::text from app_user where status='active' limit 1))::text, true);

  -- call each the way the console does. state_gap_windows and whos_on are
  -- always given a window; unbounded is not a real path and is genuinely
  -- expensive for them.
  for fname in select jsonb_object_keys(function_keys) loop
    if fname in ('state_gap_windows','whos_on') then
      execute format('select public.%I(%L::date, %L::date)', fname, '2026-08-25', '2026-08-31') into j;
    else
      execute format('select public.%I()', fname) into j;
    end if;
    for want in select jsonb_array_elements_text(function_keys->fname) loop
      if not (j ? want) then
        raise exception 'deployed %() no longer returns "%" - the console reads it', fname, want;
      end if;
    end loop;
  end loop;

  -- SIGN-IN PATH: called unbounded, must stay interactive
  t0 := clock_timestamp();
  perform public.shift_summary();
  ms := extract(epoch from clock_timestamp()-t0)*1000;
  if ms > 3000 then
    raise exception 'shift_summary() unbounded took % ms - the sign-in path regressed', round(ms);
  end if;

  t0 := clock_timestamp();
  perform public.coverage_grid();
  ms := extract(epoch from clock_timestamp()-t0)*1000;
  if ms > 3000 then
    raise exception 'coverage_grid() unbounded took % ms - the background wave regressed', round(ms);
  end if;

  -- the two shift_summary paths (clamped vs hour-expanded) must agree on the
  -- same window; they answer the same question and diverged by 2h once
  if (public.shift_summary('2026-08-01','2026-08-07')->>'total_hours')::numeric
     <> (public.shift_summary('2026-08-01','2026-08-07',null,null,0,23,array[1,2,3,4,5,6,7])->>'total_hours')::numeric then
    raise exception 'the clamped and expanded shift_summary paths disagree on the same window';
  end if;

  -- filters must narrow, never widen
  if (public.shift_summary('2026-08-01','2026-08-07',null,null,9,17)->>'total_hours')::numeric
     > (public.shift_summary('2026-08-01','2026-08-07')->>'total_hours')::numeric then
    raise exception 'narrowing hours returned MORE hours than the full day';
  end if;

  -- INTERACTIVE PATHS: every filter change refetches, so these are per-click.
  -- whos_on once took 45s for a seven-day window, which read as "broken".
  t0 := clock_timestamp(); perform public.whos_on('2026-08-25','2026-08-31');
  ms := extract(epoch from clock_timestamp()-t0)*1000;
  if ms > 2000 then raise exception 'whos_on(7d) took % ms - the tab is unusable', round(ms); end if;
  raise notice 'whos_on(7d): % ms', round(ms);

  t0 := clock_timestamp(); perform public.state_gap_windows('2026-08-25','2026-08-31');
  ms := extract(epoch from clock_timestamp()-t0)*1000;
  if ms > 2500 then raise exception 'state_gap_windows(7d) took % ms - too slow per filter change', round(ms); end if;
  raise notice 'state_gap_windows(7d): % ms', round(ms);

  -- SELF-CONSISTENCY: a row that claims N states are uncovered must name N
  -- states. whos_on coalesced a missing uncovered-row to 51 instead of 0, so a
  -- fully covered hour claimed all 51 uncovered while listing none - a false
  -- alarm on 157 of 168 rows.
  if exists (
    select 1 from jsonb_array_elements(public.whos_on('2026-08-25','2026-08-31')->'rows') e
    where (e->>9)::int > 0 and coalesce(e->>10,'') = '') then
    raise exception 'whos_on has rows claiming uncovered states while naming none';
  end if;
  if exists (
    select 1 from jsonb_array_elements(public.whos_on('2026-08-25','2026-08-31')->'rows') e
    where (e->>9)::int > 0
      and array_length(string_to_array(trim(e->>10),' '),1) <> (e->>9)::int) then
    raise exception 'whos_on uncovered COUNT disagrees with its own uncovered LIST';
  end if;

  raise notice 'contract: all deployed functions answer what the console reads, within budget';
end $$;
