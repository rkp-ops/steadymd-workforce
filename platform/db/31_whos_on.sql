-- ============================================================================
-- 31_whos_on.sql - who is on the schedule, by hour
--
-- This function previously existed ONLY in the database: it was applied live in
-- an earlier session and never committed, so there was no version-controlled
-- copy to review or diff. That is why the two defects below survived.
--
-- CORRECTNESS. The uncovered-states subquery emits a row only for an (hour,
-- state) pair that IS uncovered, so a MISSING row means "every state is covered
-- that hour" = 0. It was coalesced to 51 - the exact opposite - so a fully
-- covered hour reported all 51 states uncovered while naming none of them.
-- Measured on Aug 25-31: 168 hours, all staffed; 157 of them claimed 51 states
-- uncovered with an empty list. The true answer for those 157 is zero, and only
-- 11 hours have any uncovered state. A false alarm on 93% of rows, repeated
-- down the whole tab.
--
-- PERFORMANCE. The roster join was
--   lower(s.clinician_email_raw) = any(array(select lower(x) from unnest(r.emails) x))
-- which forces a nested loop re-running the unnest per (shift x roster) pair:
-- 44,896ms for a SEVEN DAY window. That is why the tab read as broken rather
-- than slow. Flattening the roster to one row per lowercased email first makes
-- it a hash join: ~350ms. The calendar list also rebuilt the entire hour
-- expansion a second time purely to count it; it reuses the single expansion.
--
-- The unknown-credential bucket is a plain hyphen, never an em dash.
-- ============================================================================
create or replace function public.whos_on(
    p_from date default null, p_to date default null,
    p_service_line text[] default null, p_cred text[] default null)
  returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare out jsonb; lo date; hi date;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode='42501'; end if;
  select coalesce(p_from, min((start_at at time zone 'UTC')::date)),
         coalesce(p_to,   max((start_at at time zone 'UTC')::date))
    into lo, hi from shift;

  drop table if exists _wr; drop table if exists _wo; drop table if exists _wls;

  -- one row per lowercased email. Do not inline this back into the join
  -- condition: that is the 44,896ms version.
  create temp table _wr on commit drop as
  select distinct on (lower(e)) lower(e) em,
         coalesce(public.cred_bucket(r.credential),'-') cred, r.license_states ls
  from clinician_roster r cross join lateral unnest(r.emails) e
  order by lower(e), r.id;
  create index on _wr(em);

  -- ONE hour expansion, reused by every output below
  create temp table _wo on commit drop as
  select distinct lower(s.clinician_email_raw) em, (h)::date d, extract(hour from h)::int hr,
         coalesce(rt.cred,'-') cred, s.service_line ent, rt.ls
  from shift s
  left join _wr rt on rt.em = lower(s.clinician_email_raw)
  cross join lateral generate_series(
    date_trunc('hour', s.start_at at time zone 'UTC'),
    (s.end_at at time zone 'UTC') - interval '1 second', interval '1 hour') h
  where lower(coalesce(s.clinician_email_raw,'')) <> 'not assigned'
    and s.start_at is not null and s.end_at is not null and s.end_at > s.start_at
    and (h)::date between lo and hi
    and (p_service_line is null or s.service_line = any(p_service_line))
    and (p_cred is null or coalesce(rt.cred,'-') = any(p_cred));
  create index on _wo(d, hr);

  -- states covered in each HOUR = union of the licences of whoever is on then
  create temp table _wls on commit drop as
  select w.d, w.hr, ls.st
  from _wo w cross join lateral unnest(w.ls) ls(st)
  group by w.d, w.hr, ls.st;
  create index on _wls(d, hr, st);

  select jsonb_build_object(
    'window', jsonb_build_object('from', lo, 'to', hi),
    'loaded', (select jsonb_build_object('min',min((start_at at time zone 'UTC')::date),
                                         'max',max((start_at at time zone 'UTC')::date)) from shift),
    'calendars', coalesce((select jsonb_agg(jsonb_build_array(c.ent, c.bodies, c.hours) order by c.ent)
       from (select w.ent, count(distinct w.em) bodies, count(*) hours
             from _wo w where w.ent is not null group by w.ent) c), '[]'::jsonb),
    -- [date, hour, total, doc, np, pa, ma, gc, ms, n_states_uncovered, list]
    -- coalesce to 0, NOT 51: every row in `g` comes from _wo, which only holds
    -- hours that have somebody on, so a missing uncovered-row means covered.
    'rows', coalesce((select jsonb_agg(jsonb_build_array(
              to_char(g.d,'YYYY-MM-DD'), g.hr, g.tot, g.doc, g.np, g.pa, g.ma, g.gc, g.ms,
              coalesce(u.nun,0), coalesce(u.lst,'')) order by g.d, g.hr)
       from (select w.d, w.hr,
               count(distinct w.em) tot,
               count(distinct w.em) filter (where w.cred='Doctor') doc,
               count(distinct w.em) filter (where w.cred='NP') np,
               count(distinct w.em) filter (where w.cred='PA') pa,
               count(distinct w.em) filter (where w.cred='MA') ma,
               count(distinct w.em) filter (where w.cred='GC') gc,
               count(distinct w.em) filter (where w.cred='MS') ms
             from _wo w group by w.d, w.hr) g
       left join (
         select z.d, z.hr, count(*) nun, string_agg(z.st,' ' order by z.st) lst from (
           select dh.d, dh.hr, s.st
           from (select distinct w2.d, w2.hr from _wo w2) dh
           cross join (select unnest(array['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
             'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH',
             'OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']) st) s
           where not exists (select 1 from _wls l where l.d=dh.d and l.hr=dh.hr and l.st=s.st)
         ) z group by z.d, z.hr) u on u.d=g.d and u.hr=g.hr), '[]'::jsonb),
    'peak', coalesce((select max(x.t) from (select count(distinct w.em) t from _wo w group by w.d,w.hr) x), 0),
    'total_bodies', (select count(distinct w.em) from _wo w)
  ) into out;
  return out;
end $$;
revoke all on function public.whos_on(date,date,text[],text[]) from public;
grant execute on function public.whos_on(date,date,text[],text[]) to anon, authenticated;
