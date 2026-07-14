-- ============================================================================
-- 14_sla_targets.sql
-- Contract SLA targets behind the Performance tab's scoreboard. Applied live to
-- project eeszygextbqglayglvfm as migration  sla_targets.
--
-- The console already computes each partner's live SLA attainment (share of
-- SLIs met) from sli_response. This adds the OTHER half of a scoreboard: the
-- contractual target to measure it against. Targets are DATA, not hardcoded —
-- an admin edits them in-console and the scoreboard updates on the next load,
-- so the numbers stay owned by ops and survive as contracts change.
--
-- partner_key is a normalized match substring (e.g. 'transcarent') tested
-- against the live partner name (e.g. '98point6 Transcarent'), so one target
-- lands on whatever the export happens to call that partner. label is the
-- display name. target/warn/critical are attainment fractions (0..1): at or
-- above target = on track, at/above warn = watch, below = breach risk. note
-- carries the human contract detail (the formal breach rule, the time
-- threshold) that the ~5-week window can't compute directly.
--
-- Seed values are the legacy tool's response-time contracts, as a STARTING
-- POINT for ops to correct — uptime/CSAT metrics are omitted (not derivable
-- from the response log).
-- ============================================================================

create table if not exists public.sla_target (
  partner_key text primary key,               -- normalized match substring
  label       text not null,
  tier        int,
  target      numeric not null check (target   >= 0 and target   <= 1),
  warn        numeric not null check (warn     >= 0 and warn     <= 1),
  critical    numeric not null check (critical >= 0 and critical <= 1),
  note        text,
  updated_by  uuid references public.app_user(id) on delete set null,
  updated_at  timestamptz not null default now()
);
alter table public.sla_target enable row level security;
-- no direct policy: served through SECURITY DEFINER RPCs only.

-- Seed: legacy response-time contracts (idempotent — never clobbers edits).
insert into public.sla_target (partner_key, label, tier, target, warn, critical, note) values
  ('transcarent', 'Transcarent',   1, 0.95, 0.90, 0.75, 'First contact ≤10 min · breach: 3 consecutive months <75%'),
  ('lifemd',      'LifeMD',        2, 0.90, 0.80, 0.80, 'Sync ≤60 min / Async ≤4 hrs'),
  ('ez health',   'EZ Health',     2, 0.90, 0.80, 0.80, 'Primary 90% in 24 hr · breach: 2 consecutive monthly misses'),
  ('ixlayer',     'ixLayer / J&J', 3, 0.95, 0.85, 0.80, 'Tech Sev1 ≤4 hrs / Clinical ≤1 business day')
on conflict (partner_key) do nothing;

-- 1. sla_targets() — the console reader.
create or replace function public.sla_targets()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'partner_key', t.partner_key, 'label', t.label, 'tier', t.tier,
    'target', t.target, 'warn', t.warn, 'critical', t.critical, 'note', t.note,
    'updated_by', u.email, 'updated_at', t.updated_at
  ) order by t.tier nulls last, t.label), '[]'::jsonb)
  into out from public.sla_target t left join public.app_user u on u.id = t.updated_by;
  return out;
end $$;

-- 2. admin_set_sla_target(...) — upsert one target (admin only).
create or replace function public.admin_set_sla_target(
  p_key text, p_label text, p_tier int, p_target numeric, p_warn numeric, p_critical numeric, p_note text default null)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_me uuid; v_row public.sla_target; v_key text := lower(trim(p_key));
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  if v_key is null or v_key = '' then raise exception 'a partner match key is required'; end if;
  if coalesce(p_label,'') = '' then raise exception 'a label is required'; end if;
  if p_target is null or p_target < 0 or p_target > 1 or p_warn < 0 or p_warn > 1 or p_critical < 0 or p_critical > 1 then
    raise exception 'target, warn and critical must be fractions between 0 and 1';
  end if;
  select id into v_me from public.app_user where auth_uid = auth.uid();
  insert into public.sla_target (partner_key, label, tier, target, warn, critical, note, updated_by, updated_at)
    values (v_key, trim(p_label), p_tier, p_target, p_warn, p_critical, nullif(trim(p_note),''), v_me, now())
  on conflict (partner_key) do update
    set label = excluded.label, tier = excluded.tier, target = excluded.target,
        warn = excluded.warn, critical = excluded.critical, note = excluded.note,
        updated_by = excluded.updated_by, updated_at = now()
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
revoke all on function public.admin_set_sla_target(text,text,int,numeric,numeric,numeric,text) from public;
revoke all on function public.admin_delete_sla_target(text)                              from public;
grant execute on function public.sla_targets()                                              to anon, authenticated;
grant execute on function public.admin_set_sla_target(text,text,int,numeric,numeric,numeric,text) to anon, authenticated;
grant execute on function public.admin_delete_sla_target(text)                              to anon, authenticated;
