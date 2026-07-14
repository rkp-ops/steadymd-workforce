-- ============================================================================
-- 14_sla_targets.sql
-- Contract SLA targets behind the Performance tab's scoreboard. Applied live to
-- project eeszygextbqglayglvfm as migrations  sla_targets (initial) and
-- sla_targets_source_of_truth (this version).
--
-- Rewritten to match the Partner & Program SLA Single Source of Truth (v1.3,
-- 7/14/26). That document's non-negotiables shape the schema:
--   * MODALITY IS EXPLICIT AND INDEPENDENT. Every partner carries a stated sync
--     SLO and a stated async SLO (in minutes), or an explicit None. "A single
--     SLA per partner is invalid" — so sync_min and async_min are separate
--     columns, never one blended number.
--   * OPERATING GOAL 95%. Ops targets 95% attainment on every scored partner
--     (on-demand + dedicated), so floor = 0.95 across the board; green >=95%,
--     amber >=90%, red below. Volume-only and scheduled partners stay floor NULL
--     (not scored). The banned 15-minute sync default appears nowhere. Where a
--     partner also carries a distinct CONTRACTUAL breach line (e.g. LifeMD async
--     miss <=10% => 90%), that detail lives in its note; the 95% is the goal the
--     board grades against.
--   * PANELS ARE SEPARATE. Transcarent is a dedicated panel reported on its own;
--     scheduled-availability SLAs (EZ Health, scheduled Noom/Futur) are out of
--     scope for this response-time board; volume-only partners carry no SLA.
--   * SOURCE, NOT RECALL. The per-consult objective (Due - Received) is already
--     read into sli_response.sla_met; this table records the resolved SLOs and
--     the one contractual attainment floor (LifeMD async, miss <=10% => >=90%).
--
-- The console reads sync/async attainment per partner straight from the SLIs
-- and shows it against these SLOs; the floor drives the traffic light where one
-- exists, otherwise the row is neutral ("Tracking").
-- ============================================================================

drop function if exists public.admin_set_sla_target(text,text,int,numeric,numeric,numeric,text);
drop table if exists public.sla_target cascade;

create table public.sla_target (
  partner_key text primary key,                    -- normalized match substring
  label       text not null,
  panel       text not null default 'on_demand'
              check (panel in ('on_demand','dedicated','scheduled','volume_only')),
  sync_min    int,                                 -- sync SLO minutes; null = no sync SLA
  async_min   int,                                 -- async SLO minutes; null = no async SLA
  floor       numeric check (floor is null or (floor >= 0 and floor <= 1)),  -- contractual attainment floor; null = none (never defaulted)
  basis       text,                                -- source / confirmation
  note        text,
  sort        int not null default 100,
  updated_by  uuid references public.app_user(id) on delete set null,
  updated_at  timestamptz not null default now()
);
alter table public.sla_target enable row level security;
-- no direct policy: served through SECURITY DEFINER RPCs only.

insert into public.sla_target (partner_key, label, panel, sync_min, async_min, floor, basis, note, sort) values
  -- Dedicated panel (own dashboard, reported separately)
  ('transcarent', 'Transcarent', 'dedicated', 10, null, 0.95,
     'SLI-verified (Due - Received = 10 min)',
     'Dedicated panel, TC EMR — reported separately from the Amazon+LifeMD sync view. 10 min first contact (over 20 egregious). Uptime >=99.7%, satisfaction >=4.0.', 10),
  -- On-demand (real-time queue, response time per consult)
  ('amazon',      'Amazon Clinic', 'on_demand', 30, 240, 0.95,
     'Confirmed 4/5/26; async = Looker standard',
     'No contract on file — operating targets. Same CSL queue, sync prioritized. Aliases: Amazon Clinic, Amazon One Medical, AOM.', 20),
  ('lifemd',      'LifeMD', 'on_demand', 60, 240, 0.95,
     'Contract summary on file',
     'Ops goal 95%. Contractual async penalty if monthly miss over 10% (breach line 90%). No SLA in the first 6 months.', 30),
  ('wisp',        'Wisp', 'on_demand', null, 240, 0.95,
     'Contract + reporting convention',
     'Async only. Base report uses 4 hr for parity; 5 hr (300 min) is contractual.', 40),
  ('noom',        'Noom', 'on_demand', null, 1440, 0.95,
     'SLI read 7/13 (WSL async)',
     'Async only here (scheduled sync is separate). Flat 1,440-min clock-based SLO across both Noom programs.', 50),
  ('futur',       'Futur', 'on_demand', null, 1440, 0.95,
     'SLI read 7/13 (WSL async)',
     'Async only here. 24 business-hours SLO; both Futur programs identical.', 60),
  ('nav health',  'Nav Health Direct / GenMed', 'on_demand', null, null, 0.95,
     'Partner reference notes',
     'No minute-SLA. Cancellation rate is the true indicator (cancels near 3h45m). Async only, no shift entity, no incentives.', 70),
  -- Volume-only (no visit SLA on file)
  ('whoop',           'WHOOP', 'volume_only', null, null, null, 'Contract summary on file',
     'No visit SLA — lab review model, folds into CSL on-demand volume. Uptime <99.9% = credit; Slack 1 biz day.', 80),
  ('nolla',           'Nolla', 'volume_only', null, null, null, 'No contract / no terms surfaced', 'Volume-only, no visit SLA.', 81),
  ('open healthcare', 'OPEN Healthcare', 'volume_only', null, null, null, 'No contract / no terms surfaced', 'Volume-only, no visit SLA.', 82),
  ('oura',            'Oura', 'volume_only', null, null, null, 'No contract / no terms surfaced', 'Volume-only, no visit SLA.', 83),
  ('triangle',        'Triangle Health', 'volume_only', null, null, null, 'No contract / no terms surfaced', 'Volume-only, no visit SLA.', 84),
  -- Scheduled-availability model (out of scope for the response-time board)
  ('ez health',   'EZ Health', 'scheduled', null, null, null, 'Scheduled availability model',
     'Appointment availability: 24 hr primary / 72 hr secondary, 90% monthly. Tracked separately — out of scope for the on-demand board.', 200);

-- 1. sla_targets() — the console reader.
create or replace function public.sla_targets()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'partner_key', t.partner_key, 'label', t.label, 'panel', t.panel,
    'sync_min', t.sync_min, 'async_min', t.async_min, 'floor', t.floor,
    'basis', t.basis, 'note', t.note, 'sort', t.sort,
    'updated_by', u.email, 'updated_at', t.updated_at
  ) order by t.sort, t.label), '[]'::jsonb)
  into out from public.sla_target t left join public.app_user u on u.id = t.updated_by;
  return out;
end $$;

-- 2. admin_set_sla_target(...) — upsert one target (admin only). floor may be
--    null (no contractual attainment bar); sync_min/async_min may be null (None).
create or replace function public.admin_set_sla_target(
  p_key text, p_label text, p_panel text, p_sync_min int, p_async_min int,
  p_floor numeric, p_basis text default null, p_note text default null, p_sort int default 100)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_me uuid; v_row public.sla_target; v_key text := lower(trim(p_key));
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  if v_key is null or v_key = '' then raise exception 'a partner match key is required'; end if;
  if coalesce(p_label,'') = '' then raise exception 'a label is required'; end if;
  if p_floor is not null and (p_floor < 0 or p_floor > 1) then raise exception 'floor must be a fraction between 0 and 1'; end if;
  if coalesce(p_panel,'') not in ('on_demand','dedicated','scheduled','volume_only') then
    raise exception 'panel must be on_demand, dedicated, scheduled or volume_only';
  end if;
  select id into v_me from public.app_user where auth_uid = auth.uid();
  insert into public.sla_target (partner_key, label, panel, sync_min, async_min, floor, basis, note, sort, updated_by, updated_at)
    values (v_key, trim(p_label), p_panel, p_sync_min, p_async_min, p_floor,
            nullif(trim(p_basis),''), nullif(trim(p_note),''), coalesce(p_sort,100), v_me, now())
  on conflict (partner_key) do update
    set label = excluded.label, panel = excluded.panel, sync_min = excluded.sync_min,
        async_min = excluded.async_min, floor = excluded.floor, basis = excluded.basis,
        note = excluded.note, sort = excluded.sort, updated_by = excluded.updated_by, updated_at = now()
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- 3. admin_delete_sla_target(key) — remove a target (admin only).
create or replace function public.admin_delete_sla_target(p_key text)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  delete from public.sla_target where partner_key = lower(trim(p_key));
  return jsonb_build_object('deleted', lower(trim(p_key)));
end $$;

revoke all on function public.sla_targets()                                              from public;
revoke all on function public.admin_set_sla_target(text,text,text,int,int,numeric,text,text,int) from public;
revoke all on function public.admin_delete_sla_target(text)                              from public;
grant execute on function public.sla_targets()                                              to anon, authenticated;
grant execute on function public.admin_set_sla_target(text,text,text,int,int,numeric,text,text,int) to anon, authenticated;
grant execute on function public.admin_delete_sla_target(text)                              to anon, authenticated;
