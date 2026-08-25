-- ============================================================================
-- 29_state_gap_windows_test.sql
--
-- Run against the live database. Every assertion calls the DEPLOYED function,
-- not a reimplementation of it.
--
-- Why this file exists: the UI suite mocks the RPC, so it can only prove the
-- page renders a payload correctly. It cannot prove the payload is right. A
-- scoping bug (`c.hr = hr` binding to the subquery's own column) made the
-- function drop the hour dimension entirely and report a week containing 55
-- uncovered state-hours as fully covered. The UI tests were green throughout.
-- Verifying SQL by writing a second query that "agrees" proves nothing either -
-- that is two pieces of SQL, and only one of them ships.
--
-- Usage: run the whole file. Any failed assertion raises.
-- ============================================================================
do $$
declare
  j_all jsonb; j_biz jsonb; j_tc jsonb; j_narrow jsonb;
  expect_slots int; expect_states int;
  lo date := '2026-08-25'; hi date := '2026-08-31';
begin
  -- authenticate as a real active app user so the function's own gate is exercised
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select auth_uid::text from app_user where status='active' limit 1))::text, true);

  j_all    := public.state_gap_windows(lo, hi, null, null, 0, 23);
  j_biz    := public.state_gap_windows(lo, hi, null, null, 9, 17);
  j_narrow := public.state_gap_windows(lo, hi, null, null, 14, 14);
  j_tc     := public.state_gap_windows(lo, hi, array['Transcarent Program Schedule'], null, 0, 23);

  -- 1. INDEPENDENT ORACLE. Counted straight off the base tables with every
  -- column qualified, so it cannot inherit the function's scoping mistake.
  create temp table _oracle_cov on commit drop as
  select distinct (h)::date d, extract(hour from h)::int hr, ls.st
  from shift s
  left join service_line_map m on m.entity = s.service_line
  join clinician_roster r on lower(s.clinician_email_raw)=any(array(select lower(x) from unnest(r.emails) x))
  cross join lateral unnest(r.license_states) ls(st)
  cross join lateral generate_series(date_trunc('hour', s.start_at at time zone 'UTC'),
        (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') h
  where lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
    and s.end_at > s.start_at and (h)::date between lo and hi
    and coalesce(m.count_in_coverage, true);

  select count(*), count(distinct sl.st) into expect_slots, expect_states
  from (select gd.d, gh.hr, gs.st
        from (select generate_series(lo,hi,interval '1 day')::date d) gd
        cross join (select generate_series(0,23) hr) gh
        cross join (select unnest(array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
          'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH',
          'OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']) st) gs) sl
  where not exists (select 1 from _oracle_cov c where c.d=sl.d and c.hr=sl.hr and c.st=sl.st);

  if (j_all->>'gap_slots')::int <> expect_slots then
    raise exception 'gap_slots %, oracle says % - the hour dimension is being dropped',
      j_all->>'gap_slots', expect_slots;
  end if;
  if (j_all->>'states_with_gap')::int <> expect_states then
    raise exception 'states_with_gap %, oracle says %', j_all->>'states_with_gap', expect_states;
  end if;

  -- 2. Per-state gap_hours must sum to gap_slots.
  -- window LENGTHS must sum to the raw uncovered-hour count
  if (select coalesce(sum((w->>5)::int),0) from jsonb_array_elements(j_all->'windows') w)
     <> (j_all->>'gap_slots')::int then
    raise exception 'window lengths do not reconcile with gap_slots';
  end if;
  -- every window must carry who was on shift and a credential breakdown that
  -- adds up to that headcount; the table prints both as text
  if exists (select 1 from jsonb_array_elements(j_all->'windows') w
             where (w->>7)::int > 0
               and (select coalesce(sum((m->>1)::int),0)
                    from jsonb_array_elements(w->8) m) <> (w->>7)::int) then
    raise exception 'a window credential mix does not sum to its on-shift headcount';
  end if;

  -- 3. The hour filter must actually bind. This is the regression that shipped.
  if (j_biz->>'gap_slots')::int > (j_all->>'gap_slots')::int then
    raise exception 'narrowing hours to 9-17 returned MORE gaps than 0-23';
  end if;
  if exists (select 1 from jsonb_array_elements(j_biz->'windows') w
             where (w->>2)::int not between 9 and 17
                or ((w->>4)::int - 1) not between 9 and 17) then
    raise exception 'a 9-17 window reported an hour outside 9-17';
  end if;
  if exists (select 1 from jsonb_array_elements(j_narrow->'windows') w
             where (w->>2)::int <> 14 or (w->>4)::int <> 15 or (w->>5)::int <> 1) then
    raise exception 'a single-hour window (14-14) reported something other than one 14:00 hour';
  end if;

  -- 4. Window bounds must never invert, including runs that cross midnight.
  if exists (select 1 from jsonb_array_elements(j_all->'windows') w
             where (w->>1)::date > (w->>3)::date
                or ((w->>1)::date = (w->>3)::date and (w->>2)::int >= (w->>4)::int)) then
    raise exception 'a window ends before it starts';
  end if;
  -- length must equal the real span of the run
  if exists (select 1 from jsonb_array_elements(j_all->'windows') w
             where (w->>5)::int <> ((w->>3)::date - (w->>1)::date)*24 + (w->>4)::int - (w->>2)::int) then
    raise exception 'a window length disagrees with its own start and end';
  end if;

  -- 5. SILO. "All" must exclude siloed / staffing-only calendars and say so;
  -- naming a calendar explicitly reports it alone with nothing excluded.
  if jsonb_array_length(j_all->'excluded') <>
     (select count(*) from service_line_map where not count_in_coverage) then
    raise exception 'the excluded list does not match service_line_map';
  end if;
  if jsonb_array_length(j_tc->'excluded') <> 0 then
    raise exception 'an explicit calendar selection should exclude nothing';
  end if;
  if (j_tc->>'gap_slots')::int <= (j_all->>'gap_slots')::int then
    raise exception 'Transcarent alone should cover far fewer state-hours than the on-demand pool';
  end if;

  -- 6. Bounds sanity: gaps can never exceed the slots the window contains.
  if (j_all->>'gap_slots')::int > (j_all->>'slots_total')::int then
    raise exception 'more gaps than slots in the window';
  end if;

  raise notice 'state_gap_windows: all assertions passed (% gap-slots across % states in % windows, % to %)',
    j_all->>'gap_slots', j_all->>'states_with_gap',
    jsonb_array_length(j_all->'windows'), lo, hi;
end $$;
