-- ============================================================================
-- 26_service_line_map.sql — entity -> partner mapping + counting rules
--
-- The shift feed speaks "entity/service line"; the consult/SLI feeds speak
-- "partner/program". This table is the single bridge, seeded from behavioral
-- evidence (in-shift consult alignment) corrected by the operator on 2026-07-24.
-- Admin-editable; every coverage/SLA computation that touches shifts must join
-- through it and honor the flags. An entity NOT in this table is treated as a
-- general pool and must be surfaced for review (never silently classified).
--
-- Classes:
--   general_pool      pooled on-demand staffing; demand = observed multi-partner mix
--   partner_dedicated bodies count ONLY for their partner, never anything else
--   staffing_only     we schedule people; work happens on the partner's own
--                     platform (never our systems). Hours count for clinician
--                     load/deviation analyses ONLY — never on-demand coverage.
--   support_routing   shifts exist so the system routes work (MA P2 calls);
--                     not clinician coverage; excluded from coverage & SLA
--   tracked_only      tally hours/volume; excluded from SLA aggregates and
--                     response-time metrics (Sanofi, ixlayer J&J)
-- Status:
--   active | dq (calendar disqualified: honor history, FLAG any shift on/after
--   dq_from as an upload error for WFM review) | discontinued (partner gone —
--   Rezilient, like Astellas & Flyte; historical only)
--
-- Naming rule (operator-delegated, fixed permanently): the on-call supply bucket
-- is labeled exactly "Transcarent On-call". All non-on-call Transcarent hours
-- group under "Transcarent". The legacy "98point6" prefix is display-suppressed;
-- SLI demand matches via demand_match='transcarent'.
-- ============================================================================

create table if not exists public.service_line_map (
  entity          text primary key,
  partner_label   text,
  class           text not null check (class in
                    ('general_pool','partner_dedicated','staffing_only','support_routing','tracked_only')),
  status          text not null default 'active' check (status in ('active','dq','discontinued')),
  dq_from         date,          -- status='dq': shifts starting on/after this date are upload errors to flag
  demand_match    text,          -- lowercase substring matched against SLI partner for demand-following (null = none)
  count_in_coverage boolean not null default true,  -- supply counts toward on-demand coverage math
  count_in_sla      boolean not null default true,  -- population's SLIs count in SLA aggregates
  note            text,
  updated_at      timestamptz not null default now(),
  updated_by      uuid
);

alter table public.service_line_map enable row level security;
drop policy if exists slm_read on public.service_line_map;
create policy slm_read on public.service_line_map for select using (public.is_active_app_user());

create or replace function public.admin_set_service_line_map(
    p_entity text, p_partner_label text, p_class text, p_status text,
    p_dq_from date, p_demand_match text, p_cov boolean, p_sla boolean, p_note text)
  returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then raise exception 'admin access required' using errcode='42501'; end if;
  insert into service_line_map as m
    (entity, partner_label, class, status, dq_from, demand_match, count_in_coverage, count_in_sla, note, updated_by)
  values (p_entity, p_partner_label, p_class, coalesce(p_status,'active'), p_dq_from, p_demand_match,
          coalesce(p_cov,true), coalesce(p_sla,true), p_note, auth.uid())
  on conflict (entity) do update set
    partner_label=excluded.partner_label, class=excluded.class, status=excluded.status,
    dq_from=excluded.dq_from, demand_match=excluded.demand_match,
    count_in_coverage=excluded.count_in_coverage, count_in_sla=excluded.count_in_sla,
    note=excluded.note, updated_at=now(), updated_by=auth.uid();
  return jsonb_build_object('ok', true, 'entity', p_entity);
end $$;
revoke all on function public.admin_set_service_line_map(text,text,text,text,date,text,boolean,boolean,text) from public;
grant execute on function public.admin_set_service_line_map(text,text,text,text,date,text,boolean,boolean,text) to authenticated;

-- Seed: operator rulings of 2026-07-24 (upsert so re-running is safe; manual
-- edits after this seed win on later re-runs ONLY via the admin RPC/UI).
insert into public.service_line_map
  (entity, partner_label, class, status, dq_from, demand_match, count_in_coverage, count_in_sla, note) values
  ('Daytime Clinical Service Line', null, 'general_pool', 'active', null, null, true, true,
   'Pooled on-demand staffing. Observed in-shift mix (Jun 1-24): Amazon 45 · Wisp 32 · Whoop 7 · NavHD 6.'),
  ('Weight Management Service Line', null, 'general_pool', 'active', null, null, true, true,
   'Pooled weight-management staffing. Observed in-shift mix: Noom 47 · Wisp 24 · Amazon 18 · Futur 8.'),
  ('Dynamic - Internal', null, 'general_pool', 'dq', '2026-08-01', null, true, true,
   'Dynamic shifts no longer offered; calendar DQ''d. Honor history; any shift on/after 2026-08-01 is an upload error - flag for WFM review.'),
  ('Wisp Schedule', 'Wisp', 'partner_dedicated', 'active', null, 'wisp', true, true,
   'Dedicated to Wisp (81% of in-shift consults).'),
  ('HealthOme Program Schedule', 'HealthOme-Live', 'partner_dedicated', 'active', null, 'healthome', true, true,
   'Dedicated to HealthOme-Live (92% in-shift). No SLI demand stream.'),
  ('EZ Health', 'Ez Health', 'partner_dedicated', 'active', null, 'ez health', true, true,
   'Dedicated hours; partial integration - clinicians document/conduct visits in the partner''s EMR via external links, so our-feed volume is partial. Cross-partner async/sync work during these shifts is common and expected.'),
  ('Whoop CITL', 'Whoop', 'partner_dedicated', 'dq', '2026-08-01', 'whoop', true, true,
   'Temporarily DQ''d calendar. Honor history; flag any shift after 2026-07-31 for WFM review.'),
  ('Transcarent Program Schedule', 'Transcarent', 'partner_dedicated', 'active', null, 'transcarent', false, false,
   'All non-on-call Transcarent hours group under "Transcarent". SLI demand arrives as "98point6 Transcarent" - matched via demand_match; the 98point6 prefix is display-suppressed. SILO (ruling 2026-07-24): TC is analyzed completely separately - never an aggregate addition or influencer in any blended metric; same computations run TC-only. TC clinicians on TC shifts do essentially only TC work. No borrowed global rates: handle-time-dependent TC numbers are UNAVAILABLE until a fresh export carries TC consult rows.'),
  ('Transcarent Program Schedule September', 'Transcarent', 'partner_dedicated', 'active', null, 'transcarent', false, false,
   'Variant calendar; groups under "Transcarent". SILO - see Transcarent Program Schedule note.'),
  ('98point6 Transcarent On Call', 'Transcarent On-call', 'partner_dedicated', 'active', null, 'transcarent', false, false,
   'On-call bucket, labeled exactly "Transcarent On-call" (fixed naming). Supply reported separately from hourly "Transcarent"; serves the same demand. SILO - see Transcarent Program Schedule note.'),
  ('MA P2 Calls', null, 'support_routing', 'active', null, null, false, false,
   'ALL priority-2 calls, fulfilled exclusively by MAs (not Quest-specific). Shifts exist so the system routes visits/consults to MAs - not clinician coverage. Future home of CV-call tracking. Tally hours; never in coverage or SLA math.'),
  ('Thirty Madison - SRH', 'Thirty Madison', 'staffing_only', 'active', null, null, false, false,
   'Staffing-only partner (30M): scheduled people work on the partner''s own platform, never in our systems. Hours count for clinician load/deviation analyses only.'),
  ('Thirty Madison - Mental Health', 'Thirty Madison', 'staffing_only', 'active', null, null, false, false,
   'Staffing-only (30M). See SRH note.'),
  ('Thirty Madison - Weight Loss', 'Thirty Madison', 'staffing_only', 'active', null, null, false, false,
   'Staffing-only (30M). See SRH note.'),
  ('Rezilient On Call Program Schedule', 'Rezilient', 'partner_dedicated', 'discontinued', null, null, false, false,
   'Rezilient is no longer a partner (as with Astellas and Flyte). Historical only.'),
  ('Sanofi-ixlayer', 'Sanofi-ixlayer', 'tracked_only', 'active', null, null, false, false,
   'Tally hours/consults; excluded from SLA aggregates, response-time metrics, and all gauges (limited volume).'),
  ('Sanofi Skinlink', 'Sanofi-ixlayer', 'tracked_only', 'active', null, null, false, false,
   'Groups with Sanofi-ixlayer; tracked only.'),
  ('ixlayer J & J - Bridge Insurance', 'ixlayer', 'tracked_only', 'active', null, null, false, false,
   'Tally hours; ignore visits in metric calculations and performance numbers.')
on conflict (entity) do update set
  partner_label=excluded.partner_label, class=excluded.class, status=excluded.status,
  dq_from=excluded.dq_from, demand_match=excluded.demand_match,
  count_in_coverage=excluded.count_in_coverage, count_in_sla=excluded.count_in_sla,
  note=excluded.note, updated_at=now();
