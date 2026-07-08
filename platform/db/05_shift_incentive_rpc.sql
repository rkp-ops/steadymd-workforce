-- ============================================================================
-- 05_shift_incentive_rpc.sql
-- Shift-hours and incentive-dollar summaries for the console's Shifts and
-- Incentives tabs. Applied live to project eeszygextbqglayglvfm as migrations
-- shift_incentive_provenance_and_load + shift_incentive_summary_rpcs.
--
-- The raw scheduling and payout exports are loaded into public.shift and
-- public.incentive. Clinician credential (for shifts) and license type (for
-- incentives) are resolved from the roster at load time and stored on the row,
-- so these summaries are plain group-bys with no join. Both functions gate on
-- is_active_app_user(); anon REST calls return 401 (verified).
--
-- Sibling live feeds, applied in earlier migrations, follow the same pattern:
--   sli_dataset()        raw SLI rows for client-side Performance/Overview
--   consult_summary()    modality-first consult rollup (lab excluded)
-- ============================================================================

ALTER TABLE public.shift     ADD COLUMN IF NOT EXISTS clinician_email_raw text;
ALTER TABLE public.shift     ADD COLUMN IF NOT EXISTS clinician_name_raw  text;
ALTER TABLE public.shift     ADD COLUMN IF NOT EXISTS clinician_cred      text;  -- resolved from roster
ALTER TABLE public.incentive ADD COLUMN IF NOT EXISTS license_type        text;  -- from the payout export
ALTER TABLE public.incentive ADD COLUMN IF NOT EXISTS clinician_name_raw  text;
ALTER TABLE public.incentive ADD COLUMN IF NOT EXISTS clinician_email_raw text;

CREATE OR REPLACE FUNCTION public.shift_summary() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_active_app_user() THEN RAISE EXCEPTION 'not authorized' USING errcode='42501'; END IF;
  RETURN (SELECT jsonb_build_object(
    'total_hours', (SELECT round(sum(hours)::numeric,1) FROM public.shift),
    'n_shifts', (SELECT count(*) FROM public.shift),
    'n_clinicians', (SELECT count(DISTINCT clinician_email_raw) FROM public.shift),
    'range', (SELECT jsonb_build_object('min',min(start_at)::date::text,'max',max(start_at)::date::text) FROM public.shift),
    'by_service_line', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.hours DESC) FROM (
       SELECT coalesce(service_line,'(unspecified)') AS name, round(sum(hours)::numeric,1) AS hours, count(*) AS shifts
       FROM public.shift GROUP BY service_line) t),
    'by_cred', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.hours DESC) FROM (
       SELECT coalesce(clinician_cred,'—') AS name, round(sum(hours)::numeric,1) AS hours, count(*) AS shifts
       FROM public.shift GROUP BY clinician_cred) t),
    'top_clin', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.hours DESC) FROM (
       SELECT clinician_name_raw AS name, coalesce(clinician_cred,'—') AS cred, round(sum(hours)::numeric,1) AS hours, count(*) AS shifts
       FROM public.shift WHERE clinician_name_raw IS NOT NULL GROUP BY clinician_name_raw, clinician_cred ORDER BY sum(hours) DESC LIMIT 15) t)
  ));
END; $$;

CREATE OR REPLACE FUNCTION public.incentive_summary() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_active_app_user() THEN RAISE EXCEPTION 'not authorized' USING errcode='42501'; END IF;
  RETURN (SELECT jsonb_build_object(
    'total_usd', (SELECT round((sum(amount_cents)/100.0)::numeric,2) FROM public.incentive),
    'n_items', (SELECT count(*) FROM public.incentive),
    'n_clinicians', (SELECT count(DISTINCT clinician_email_raw) FROM public.incentive),
    'range', (SELECT jsonb_build_object('min',min(launched_at)::date::text,'max',max(launched_at)::date::text) FROM public.incentive),
    'by_license', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.usd DESC) FROM (
       SELECT coalesce(license_type,'—') AS name, round((sum(amount_cents)/100.0)::numeric,2) AS usd, count(*) AS n FROM public.incentive GROUP BY license_type) t),
    'by_partner', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.usd DESC) FROM (
       SELECT coalesce(partner,'—') AS name, round((sum(amount_cents)/100.0)::numeric,2) AS usd, count(*) AS n FROM public.incentive GROUP BY partner) t),
    'by_program', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.usd DESC) FROM (
       SELECT coalesce(program,'—') AS name, round((sum(amount_cents)/100.0)::numeric,2) AS usd, count(*) AS n FROM public.incentive GROUP BY program ORDER BY sum(amount_cents) DESC LIMIT 12) t),
    'by_incentive', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.usd DESC) FROM (
       SELECT coalesce(incentive_name,'—') AS name, round((sum(amount_cents)/100.0)::numeric,2) AS usd, count(*) AS n FROM public.incentive GROUP BY incentive_name) t),
    'top_earners', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.usd DESC) FROM (
       SELECT clinician_name_raw AS name, coalesce(license_type,'—') AS license, round((sum(amount_cents)/100.0)::numeric,2) AS usd, count(*) AS n
       FROM public.incentive WHERE clinician_name_raw IS NOT NULL GROUP BY clinician_name_raw, license_type ORDER BY sum(amount_cents) DESC LIMIT 15) t)
  ));
END; $$;

REVOKE ALL ON FUNCTION public.shift_summary()     FROM public;
REVOKE ALL ON FUNCTION public.incentive_summary() FROM public;
GRANT EXECUTE ON FUNCTION public.shift_summary()     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.incentive_summary() TO anon, authenticated;
