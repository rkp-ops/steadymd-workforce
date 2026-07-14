-- ============================================================================
-- 11_user_admin.sql
-- Admin-only access management: the RPCs behind the console's Users tab.
-- Applied live to project eeszygextbqglayglvfm as migration  user_admin_rpcs.
--
-- The access model (see 01_canonical_model.sql) is invitation-only: a person
-- can read the console only when they have an ACTIVE app_user row whose
-- auth_uid is linked to their Supabase Auth login. An admin "provisions" access
-- by pre-authorizing an email + role; on that person's first confirmed sign-in,
-- claim_app_user() links their auth_uid by email and the role takes effect.
-- These RPCs let an admin do all of that from the console instead of by hand in
-- SQL — list who has access, provision a new email, change a role, or revoke.
--
-- Every function is is_admin()-gated, SECURITY DEFINER (so it can see/write the
-- RLS-protected app_user table), REVOKEd from public and GRANTed to the browser
-- roles like the other console RPCs. Creating the actual Auth login is still a
-- Supabase-Auth step (the documented foundation gap); provisioning here means
-- the moment that login exists, the person is recognized with the role set.
--
-- Safety rails enforced server-side (a client can't bypass them):
--   * can't remove or disable the LAST active admin (would lock everyone out),
--   * can't disable your own access mid-session.
-- ============================================================================

-- Dedupe guard: one app_user per email (case-insensitive). Clean on current
-- data; enforces going forward so provisioning can't fork a person into two rows.
create unique index if not exists app_user_email_lower_key
  on public.app_user (lower(email));

-- 1. admin_list_users() — everyone with (or pending) access, newest first, with
--    last-seen and view count folded in from the access log.
create or replace function public.admin_list_users()
  returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  with la as (
    select app_user_id, max(created_at) last_seen, count(*) n_views
    from public.access_log group by app_user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id, 'email', u.email, 'name', u.display_name,
    'role', u.role, 'status', u.status,
    'claimed', (u.auth_uid is not null),   -- false = provisioned but hasn't signed in yet
    'is_self', (u.auth_uid = auth.uid()),
    'invited_by', inv.email,
    'created_at', u.created_at,
    'last_seen', la.last_seen,
    'views', coalesce(la.n_views, 0)
  ) order by u.created_at desc), '[]'::jsonb)
  into out
  from public.app_user u
  left join la on la.app_user_id = u.id
  left join public.app_user inv on inv.id = u.invited_by;
  return out;
end $$;

-- 2. admin_provision_user(email, role, name) — pre-authorize (or reactivate) an
--    email. Idempotent on the email: an existing row is refreshed to active with
--    the given role, otherwise a new pending row is minted.
create or replace function public.admin_provision_user(
  p_email text, p_role public.app_role default 'viewer', p_name text default null)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_me uuid; v_row public.app_user; v_email text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  if v_email is null or v_email = '' or position('@' in v_email) = 0 then
    raise exception 'a valid email is required';
  end if;
  select id into v_me from public.app_user where auth_uid = auth.uid();
  select * into v_row from public.app_user where lower(email) = v_email;
  if found then
    update public.app_user
       set role = p_role, status = 'active',
           display_name = coalesce(nullif(trim(p_name), ''), display_name)
     where id = v_row.id returning * into v_row;
  else
    insert into public.app_user (email, display_name, role, status, invited_by)
      values (v_email, nullif(trim(p_name), ''), p_role, 'active', v_me)
      returning * into v_row;
  end if;
  return to_jsonb(v_row);
end $$;

-- 3. admin_set_user_role(id, role) — promote/demote, with last-admin guard.
create or replace function public.admin_set_user_role(p_id uuid, p_role public.app_role)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_row public.app_user; v_target public.app_user;
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  select * into v_target from public.app_user where id = p_id;
  if not found then raise exception 'user not found'; end if;
  if v_target.role = 'admin' and p_role <> 'admin'
     and (select count(*) from public.app_user where role = 'admin' and status = 'active') <= 1 then
    raise exception 'can''t remove the last active admin';
  end if;
  update public.app_user set role = p_role where id = p_id returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- 4. admin_set_user_status(id, status) — revoke/restore access, with
--    self-lockout and last-admin guards.
create or replace function public.admin_set_user_status(p_id uuid, p_status public.app_user_status)
  returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_row public.app_user; v_target public.app_user;
begin
  if not public.is_admin() then raise exception 'not authorized' using errcode = '42501'; end if;
  select * into v_target from public.app_user where id = p_id;
  if not found then raise exception 'user not found'; end if;
  if v_target.auth_uid = auth.uid() and p_status = 'disabled' then
    raise exception 'you can''t disable your own access';
  end if;
  if v_target.role = 'admin' and v_target.status = 'active' and p_status = 'disabled'
     and (select count(*) from public.app_user where role = 'admin' and status = 'active') <= 1 then
    raise exception 'can''t disable the last active admin';
  end if;
  update public.app_user set status = p_status where id = p_id returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- Browser-facing like the other console RPCs; is_admin() inside each body is the
-- real gate, so a non-admin (or anon) call just returns 42501.
revoke all on function public.admin_list_users()                          from public;
revoke all on function public.admin_provision_user(text, public.app_role, text) from public;
revoke all on function public.admin_set_user_role(uuid, public.app_role)  from public;
revoke all on function public.admin_set_user_status(uuid, public.app_user_status) from public;
grant execute on function public.admin_list_users()                          to anon, authenticated;
grant execute on function public.admin_provision_user(text, public.app_role, text) to anon, authenticated;
grant execute on function public.admin_set_user_role(uuid, public.app_role)  to anon, authenticated;
grant execute on function public.admin_set_user_status(uuid, public.app_user_status) to anon, authenticated;
