-- ============================================================================
-- 34_upload_admin.sql - list and remove already-loaded uploads
--
-- The importer is deliberately non-destructive: every loaded row carries a
-- source_upload provenance, uploads MERGE in (upsert by natural key) and nothing
-- is ever deleted. That is safe, but it left no way to take a bad / duplicate /
-- test file back out once loaded. These two admin-only functions add that.
--
-- A single file is chunked on upload (CHUNK_ROWS rows per part) and re-uploaded
-- across sessions, so source_upload holds MANY rows per logical document. Both
-- functions therefore work on the logical document = (source_kind, filename),
-- and the delete removes every row tagged to ANY of that document's chunks.
--
-- Kept on purpose: ingest_partner_snapshot (source_upload_id is ON DELETE SET
-- NULL) detaches rather than being deleted; identity/learned links live on their
-- own tables and are untouched, so a re-load re-attributes cleanly.
-- ============================================================================

-- Logical uploads, newest first: one row per (kind, filename).
create or replace function public.admin_list_uploads()
  returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'admin access required' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', g.source_kind, 'filename', g.filename,
           'parts', g.parts, 'last_uploaded_at', g.last_at
         ) order by g.last_at desc), '[]'::jsonb)
    into out
  from (select source_kind, filename, count(*) parts, max(uploaded_at) last_at
        from source_upload group by source_kind, filename) g;
  return out;
end $$;
revoke all on function public.admin_list_uploads() from public;
grant execute on function public.admin_list_uploads() to authenticated;

-- Remove one logical document: delete every row tagged to any of its chunks
-- across the data tables, then the source_upload rows themselves.
create or replace function public.admin_delete_upload(p_kind text, p_filename text)
  returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ids uuid[]; d jsonb = '{}'::jsonb; n int;
begin
  if not public.is_admin() then raise exception 'admin access required' using errcode='42501'; end if;
  select array_agg(id) into ids from source_upload
    where source_kind = p_kind and filename is not distinct from p_filename;
  if ids is null then raise exception 'no such upload' using errcode='P0002'; end if;

  delete from consult_touch     where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('consult_touch', n);
  delete from consult           where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('consult', n);
  delete from sli_response      where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('sli_response', n);
  delete from shift             where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('shift', n);
  delete from incentive         where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('incentive', n);
  delete from clinician_license where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('clinician_license', n);
  delete from clinician_roster  where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('clinician_roster', n);
  delete from data_gap_flag     where source_upload_id = any(ids); get diagnostics n = row_count; d = d || jsonb_build_object('data_gap_flag', n);
  delete from source_upload     where id = any(ids);               get diagnostics n = row_count; d = d || jsonb_build_object('source_upload', n);

  return jsonb_build_object('ok', true, 'kind', p_kind, 'filename', p_filename, 'deleted', d);
end $$;
revoke all on function public.admin_delete_upload(text,text) from public;
grant execute on function public.admin_delete_upload(text,text) to authenticated;
