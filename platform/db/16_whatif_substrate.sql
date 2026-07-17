-- ============================================================================
-- 16_whatif_substrate.sql
-- Ground-truth substrate for the What-If planning engine. Applied live to
-- project eeszygextbqglayglvfm as migration  whatif_substrate_rpc.
--
-- The What-If engine models counterfactuals ("what if SC participation went from
-- 15% to 40%"), but a counterfactual is only credible if it sits on real, current
-- ground truth. This RPC returns ONLY facts — never a model. Every modeled number,
-- every imputation, every confidence band is computed in the pure client core
-- (platform/web/whatif.core.mjs), so the honesty layer lives in one place and this
-- function can never quietly fabricate. It returns, per state:
--
--   * licensed     — distinct roster clinicians licensed in the state
--                    (clinician_roster.license_states, the loader's licensure array)
--   * participated — distinct roster clinicians who ACTUALLY worked the state
--                    recently (clinician_roster.active_states, built from SLI state
--                    activity within the 90-day active window). This is the framing
--                    correction the spec insists on: for the restricted states the
--                    constraint is participation, not licensure.
--   * decided/met + sync/async splits — SLA attainment from sli_response, where
--                    sla_met = (completed <= due) is a generated column. Modality is
--                    read from consult_type (SLI GUIDs don't overlap the consult
--                    table, so we classify in place): sync = video / urgent-care /
--                    phone; async = messaging / chart / lab / addendum.
--
-- Plus the volume-weighted `aggregate` (so the client can show local lift vs.
-- weighted-aggregate contribution side by side — the second framing correction).
-- Gated + granted exactly like every other console RPC.
-- ============================================================================

create or replace function public.whatif_coverage()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb; win record;
begin
  if not public.is_active_app_user() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select min(sli_received)::date lo, max(sli_received)::date hi,
         count(distinct date_trunc('week', sli_received))::int weeks
    into win from sli_response where sli_received is not null;

  with modclass as (
    select state, sla_met,
      case when consult_type in ('video_chat','urgent-care')
                or consult_type like 'critical_values_phone_call%'
           then 'sync' else 'async' end modality
    from sli_response
  ),
  st_sla as (
    select state,
      count(*) filter (where sla_met is not null) decided,
      count(*) filter (where sla_met) met,
      count(*) filter (where modality='sync'  and sla_met is not null) sy_dec,
      count(*) filter (where modality='sync'  and sla_met) sy_met,
      count(*) filter (where modality='async' and sla_met is not null) as_dec,
      count(*) filter (where modality='async' and sla_met) as_met
    from modclass where state is not null group by state
  ),
  lic  as (select s state, count(*) licensed
           from clinician_roster r, unnest(r.license_states) s group by s),
  part as (select s state, count(*) participated
           from clinician_roster r, unnest(r.active_states) s group by s),
  keys as (select state from st_sla union select state from lic union select state from part),
  states as (
    select k.state st, coalesce(l.licensed,0) licensed, coalesce(p.participated,0) participated,
           coalesce(s.decided,0) decided, coalesce(s.met,0) met,
           coalesce(s.sy_dec,0) sy_dec, coalesce(s.sy_met,0) sy_met,
           coalesce(s.as_dec,0) as_dec, coalesce(s.as_met,0) as_met
    from keys k
    left join st_sla s on s.state=k.state
    left join lic l on l.state=k.state
    left join part p on p.state=k.state
    where k.state is not null and k.state <> ''
  ),
  agg as (
    select sum(decided) decided, sum(met) met, sum(sy_dec) sy_dec, sum(sy_met) sy_met,
           sum(as_dec) as_dec, sum(as_met) as_met from states
  )
  select jsonb_build_object(
    'window', jsonb_build_object('start', win.lo, 'end', win.hi, 'weeks', coalesce(win.weeks,0)),
    'restricted', jsonb_build_array('AL','GA','IN','MO','MS','SC','TN'),
    'states', (select coalesce(jsonb_agg(jsonb_build_object(
        'st', st, 'licensed', licensed, 'participated', participated,
        'decided', decided, 'met', met,
        'sync',  jsonb_build_array(sy_dec, sy_met),
        'async', jsonb_build_array(as_dec, as_met)
      ) order by st), '[]'::jsonb) from states),
    'aggregate', (select jsonb_build_object(
        'decided', coalesce(decided,0), 'met', coalesce(met,0),
        'sync',  jsonb_build_array(coalesce(sy_dec,0), coalesce(sy_met,0)),
        'async', jsonb_build_array(coalesce(as_dec,0), coalesce(as_met,0))
      ) from agg)
  ) into out;
  return out;
end $$;

revoke all on function public.whatif_coverage() from public;
grant execute on function public.whatif_coverage() to anon, authenticated;
