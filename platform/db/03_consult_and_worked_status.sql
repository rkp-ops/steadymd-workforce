-- ============================================================================
-- 03_consult_and_worked_status.sql
-- Consult provenance columns + the configurable "moved care forward" worked-
-- status set. Applied live to project eeszygextbqglayglvfm as migration
-- `consult_provenance_and_worked_status`.
--
-- The Metabase status log (570,858 touch rows) is rolled up to 176,521 consults
-- by platform/etl/rollup_consults.py. handle_seconds is read as
-- first_worked_at -> final_status_at; for lab/async flows this elapsed span is
-- dominated by lab turnaround, NOT active clinician time, and the console
-- labels it accordingly rather than presenting it as handle time.
-- ============================================================================

-- Preserve raw clinician identity on each consult so it can be resolved to a
-- canonical clinician_id later without re-importing.
ALTER TABLE public.consult ADD COLUMN IF NOT EXISTS clinician_guid      text;
ALTER TABLE public.consult ADD COLUMN IF NOT EXISTS clinician_name_raw  text;
ALTER TABLE public.consult ADD COLUMN IF NOT EXISTS clinician_email_raw text;
CREATE INDEX IF NOT EXISTS idx_consult_clinguid ON public.consult(clinician_guid);
CREATE INDEX IF NOT EXISTS idx_consult_partner  ON public.consult(partner);

-- The worked-status set is DATA, not code: edit these rows to change what
-- "moved care forward" means. counts_as_worked drives n_worked_touches and the
-- 99.3% "moved care forward" figure.
DELETE FROM public.meaningful_status;
INSERT INTO public.meaningful_status (status_id, counts_as_worked, is_patient_facing, is_terminal, notes) VALUES
 ('completed',            true,  true,  true,  'Care delivered'),
 ('rejected',             true,  true,  true,  'Clinician declined / closed the consult'),
 ('referred_out',         true,  true,  true,  'Referred to external care'),
 ('lab_approved',         true,  false, false, 'Clinician approved the lab order'),
 ('lab_submitted',        true,  false, false, 'Clinician submitted the lab'),
 ('in_call',              true,  true,  false, 'Live visit in progress'),
 ('in_progress',          false, true,  false, 'Picked up / charting (engaged, not yet forward)'),
 ('waiting',              false, true,  false, 'Awaiting input'),
 ('ready_to_resume',      false, false, false, 'Queued to resume'),
 ('external_in_progress', false, false, false, 'External system working'),
 ('lab_results_received', false, false, false, 'Lab results returned'),
 ('lab_results_ready',    false, false, false, 'Lab results ready'),
 ('lab_results_pending',  false, false, false, 'Awaiting lab results'),
 ('lab_accepted',         false, false, false, 'Lab accepted by system'),
 ('lab_result_outreach',  false, true,  false, 'Outreach on results'),
 ('lab_sample_rejected',  false, false, false, 'Lab sample rejected'),
 ('scheduled',            false, true,  false, 'Visit scheduled'),
 ('received',             false, false, false, 'Consult received'),
 ('pending',              false, false, false, 'Pending'),
 ('assigned',             false, false, false, 'Assigned to a clinician'),
 ('canceled',             false, false, true,  'Canceled (not clinician work)'),
 ('issue',                false, false, false, 'Flagged issue');

-- NOTE: the bulk consult load used a TEMPORARY tmp_load_consult INSERT policy
-- granted to anon, dropped immediately after (migration
-- revoke_consult_load_policy). Steady state has no anon write path.
