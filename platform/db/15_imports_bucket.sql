-- ============================================================================
-- 15_imports_bucket.sql
-- Private Storage bucket that stages the monthly export uploads for the
-- in-console Import tab. Applied live to project eeszygextbqglayglvfm as
-- migration  imports_storage_bucket.
--
-- Flow: the admin drops files in the console -> browser uploads them here (this
-- RLS lets only active admins write) -> the `ingest` Edge Function downloads
-- them with the service role (which bypasses RLS), parses/loads them, and calls
-- relink_clinician_spine(). The powerful service key lives only in the Edge
-- Function's server-side env, never in the browser.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('imports', 'imports', false, 209715200)   -- private, 200 MB ceiling per file
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit;

-- Only active admins may upload / read / delete in this bucket from the browser.
-- The Edge Function uses the service role, which bypasses RLS entirely.
drop policy if exists "imports admin manage" on storage.objects;
create policy "imports admin manage" on storage.objects
  for all to authenticated
  using (bucket_id = 'imports' and public.is_admin())
  with check (bucket_id = 'imports' and public.is_admin());
