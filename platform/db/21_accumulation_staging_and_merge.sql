-- ============================================================================
-- 21_accumulation_staging_and_merge.sql
-- Applied live to eeszygextbqglayglvfm as migrations
-- `accumulation_staging_and_merge` + `accumulation_merge_fix_generated_cols`.
--
-- The accumulation engine (point 5: stop wiping, add-by-id, newest-wins). The
-- ingest edge function will PARSE -> APPEND into these *_stage tables (plain
-- inserts, no clear), then call merge_staged(), which UPSERTs staging -> main on
-- the verified natural keys and truncates staging. Then relink() runs as today.
--
-- Why staging + a DB merge instead of upserting from the edge: the correctness-
-- critical logic (dedup, newest-wins, null handling) lives in Postgres where it
-- is testable (curl to the edge function is blocked), the edge's job shrinks to
-- dumb appends (less 546 risk), and Postgres has no isolate limits.
--
-- Verified: re-uploading a key updates in place (1 row, not 2) with the newest
-- upload's values, and the generated columns (wait_seconds, sla_met, lane)
-- recompute from the new base timestamps.
--
-- Notes:
--  * sli_response has 3 GENERATED columns (lane, sla_met, wait_seconds) derived
--    from the base timestamps — the merge writes base columns only and lets
--    Postgres recompute. Staging mirrors the insertable set (generated cols + id
--    dropped).
--  * clinician_id / primary_clinician_id are NOT overwritten on update — relink
--    owns attribution and runs after the merge.
-- ============================================================================

create table if not exists sli_response_stage (like sli_response including defaults);
alter table sli_response_stage drop column if exists lane;          -- generated
alter table sli_response_stage drop column if exists sla_met;       -- generated
alter table sli_response_stage drop column if exists wait_seconds;  -- generated
alter table sli_response_stage drop column if exists id;            -- main owns identity

create table if not exists consult_stage (like consult including defaults);
create table if not exists shift_stage (like shift including defaults);
alter table shift_stage drop column if exists id;
create table if not exists incentive_stage (like incentive including defaults);
alter table incentive_stage drop column if exists id;

create or replace function public.merge_staged()
  returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare n_sli int; n_consult int; n_shift int; n_incentive int;
begin
  insert into consult (consult_guid, partner, program, service_line, consult_type, modality_class,
    reason_for_visit, is_return, created_at, first_worked_at, final_status, final_status_at,
    primary_clinician_id, n_touches, n_worked_touches, handle_seconds, source_upload_id,
    clinician_guid, clinician_name_raw, clinician_email_raw)
  select consult_guid, partner, program, service_line, consult_type, modality_class,
    reason_for_visit, is_return, created_at, first_worked_at, final_status, final_status_at,
    primary_clinician_id, n_touches, n_worked_touches, handle_seconds, source_upload_id,
    clinician_guid, clinician_name_raw, clinician_email_raw
  from consult_stage
  on conflict (consult_guid) do update set
    partner=excluded.partner, program=excluded.program, service_line=excluded.service_line,
    consult_type=excluded.consult_type, modality_class=excluded.modality_class,
    reason_for_visit=excluded.reason_for_visit, is_return=excluded.is_return,
    created_at=excluded.created_at, first_worked_at=excluded.first_worked_at,
    final_status=excluded.final_status, final_status_at=excluded.final_status_at,
    n_touches=excluded.n_touches, n_worked_touches=excluded.n_worked_touches,
    handle_seconds=excluded.handle_seconds, source_upload_id=excluded.source_upload_id,
    clinician_guid=excluded.clinician_guid, clinician_name_raw=excluded.clinician_name_raw,
    clinician_email_raw=excluded.clinician_email_raw;
  get diagnostics n_consult = row_count;

  insert into sli_response (consult_guid, clinician_id, partner, program, state, consult_type,
    sli_received, sli_due, sli_completed, sli_status_raw, during_biz_hrs,
    source_upload_id, clinician_name_raw)
  select consult_guid, clinician_id, partner, program, state, consult_type,
    sli_received, sli_due, sli_completed, sli_status_raw, during_biz_hrs,
    source_upload_id, clinician_name_raw
  from sli_response_stage
  on conflict (consult_guid, (coalesce(consult_type,'')), sli_received) do update set
    partner=excluded.partner, program=excluded.program, state=excluded.state,
    sli_due=excluded.sli_due, sli_completed=excluded.sli_completed,
    sli_status_raw=excluded.sli_status_raw, during_biz_hrs=excluded.during_biz_hrs,
    source_upload_id=excluded.source_upload_id, clinician_name_raw=excluded.clinician_name_raw;
  get diagnostics n_sli = row_count;

  insert into shift (clinician_id, shift_type, service_line, start_at, end_at, hours,
    source_upload_id, clinician_email_raw, clinician_name_raw, clinician_cred)
  select clinician_id, shift_type, service_line, start_at, end_at, hours,
    source_upload_id, clinician_email_raw, clinician_name_raw, clinician_cred
  from shift_stage
  on conflict (coalesce(clinician_email_raw,''), start_at, end_at,
               coalesce(service_line,''), coalesce(shift_type,'')) do update set
    hours=excluded.hours, source_upload_id=excluded.source_upload_id,
    clinician_name_raw=excluded.clinician_name_raw, clinician_cred=excluded.clinician_cred;
  get diagnostics n_shift = row_count;

  insert into incentive (consult_guid, clinician_id, partner, program, state, consult_type,
    launched_at, amount_cents, currency, incentive_name, budget_name, source_upload_id,
    license_type, clinician_name_raw, clinician_email_raw)
  select consult_guid, clinician_id, partner, program, state, consult_type,
    launched_at, amount_cents, currency, incentive_name, budget_name, source_upload_id,
    license_type, clinician_name_raw, clinician_email_raw
  from incentive_stage
  on conflict (consult_guid, incentive_name, launched_at, amount_cents) do update set
    partner=excluded.partner, program=excluded.program, state=excluded.state,
    consult_type=excluded.consult_type, currency=excluded.currency, budget_name=excluded.budget_name,
    source_upload_id=excluded.source_upload_id, license_type=excluded.license_type,
    clinician_name_raw=excluded.clinician_name_raw, clinician_email_raw=excluded.clinician_email_raw;
  get diagnostics n_incentive = row_count;

  truncate sli_response_stage, consult_stage, shift_stage, incentive_stage;
  return jsonb_build_object('merged_sli', n_sli, 'merged_consult', n_consult,
                            'merged_shift', n_shift, 'merged_incentive', n_incentive);
end $$;

revoke all on function public.merge_staged() from public;
grant execute on function public.merge_staged() to service_role;
