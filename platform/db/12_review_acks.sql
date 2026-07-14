-- ============================================================================
-- 12_review_acks.sql
-- Persistence for the console's Review queue. Applied live to project
-- eeszygextbqglayglvfm as migration  review_acks.
--
-- The Review tab computes flags CLIENT-SIDE from data already loaded (roster
-- corrections, the attribution artifact, productivity decline, coverage gaps),
-- so detection needs no backend. What DOES need to persist is the human
-- decision: "I've reviewed this one." This table records that acknowledgment so
-- a resolved flag stays resolved across reloads and across users, keyed on a
-- STABLE flag_key the client derives from the flag's identity (category +
-- subject) — not its transient numbers. If the underlying condition clears the
-- flag simply stops being emitted; if it re-fires later with the same identity,
-- the prior ack still applies until someone reopens it.
--
-- Any active app_user can resolve/reopen (triage is shared ops work); every ack
-- records who and when. Served through is_active_app_user()-gated RPCs like the
-- rest of the console.
-- ============================================================================

create table if not exists public.review_ack (
  flag_key   text primary key,          -- stable client-derived identity of the flag
  category   text not null,             -- roster | attribution | productivity | coverage | data-quality
  subject    text,                      -- human label captured at ack time (who/what)
  note       text,                      -- optional reviewer note
  acked_by   uuid references public.app_user(id) on delete set null,
  acked_at   timestamptz not null default now()
);
alter table public.review_ack enable row level security;
-- no direct policy: served through SECURITY DEFINER RPCs only.

-- 1. review_acks() — all current acknowledgments, with the resolver's email.
create or replace function public.review_acks()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'flag_key', a.flag_key, 'category', a.category, 'subject', a.subject,
    'note', a.note, 'acked_by', u.email, 'acked_at', a.acked_at
  ) order by a.acked_at desc), '[]'::jsonb)
  into out from public.review_ack a left join public.app_user u on u.id = a.acked_by;
  return out;
end $$;

-- 2. set_review_ack(flag_key, category, subject, note) — resolve a flag
--    (idempotent upsert; refreshes who/when on re-ack).
create or replace function public.set_review_ack(
  p_flag_key text, p_category text, p_subject text default null, p_note text default null)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_me uuid; v_row public.review_ack;
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  if p_flag_key is null or p_flag_key = '' then raise exception 'flag_key required'; end if;
  select id into v_me from public.app_user where auth_uid = auth.uid();
  insert into public.review_ack (flag_key, category, subject, note, acked_by, acked_at)
    values (p_flag_key, coalesce(p_category,'other'), p_subject, p_note, v_me, now())
  on conflict (flag_key) do update
    set category = excluded.category, subject = excluded.subject,
        note = excluded.note, acked_by = excluded.acked_by, acked_at = now()
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- 3. clear_review_ack(flag_key) — reopen a flag.
create or replace function public.clear_review_ack(p_flag_key text)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.is_active_app_user() then raise exception 'not authorized' using errcode = '42501'; end if;
  delete from public.review_ack where flag_key = p_flag_key;
  return jsonb_build_object('cleared', p_flag_key);
end $$;

revoke all on function public.review_acks()                              from public;
revoke all on function public.set_review_ack(text, text, text, text)     from public;
revoke all on function public.clear_review_ack(text)                     from public;
grant execute on function public.review_acks()                          to anon, authenticated;
grant execute on function public.set_review_ack(text, text, text, text) to anon, authenticated;
grant execute on function public.clear_review_ack(text)                 to anon, authenticated;
