-- ============================================================================
-- 06_identity_memory.sql
-- Identity memory + one-click add-to-roster, and the ingest volume-check table.
-- Applied live to project eeszygextbqglayglvfm as migrations
--   roster_decision_memory  (name_key, roster_decision, whoami, set_roster_membership)
--   ingest_partner_snapshot (per-partner load snapshots for the volume check)
--
-- Some clinicians appear only in the activity exports — no roster or license row,
-- no NPI — and land in the console's add-to-roster queue. An admin confirms one
-- from the Clinicians tab; that decision is remembered here and read back by the
-- ingestion tool on every later run, so a partial refresh never re-buries someone
-- an admin already vouched for. Gating follows the house pattern: SECURITY DEFINER
-- + an is_admin()/is_active_app_user() guard, REVOKE from public, GRANT to
-- anon+authenticated; anon calls return 401 (verified).
-- ============================================================================

-- name_key(): normalized, credential-stripped, sorted-token key for a clinician
-- name. Mirrors _nkey() in platform/ingest/identity_lib.py exactly, so a decision
-- recorded here matches the same person the loader rebuilds from the raw files.
CREATE OR REPLACE FUNCTION public.name_key(nm text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_to_string(ARRAY(
    SELECT t FROM (SELECT DISTINCT unnest(string_to_array(
        regexp_replace(lower(coalesce(nm,'')), '[,./|()-]', ' ', 'g'), ' ')) AS t) s
    WHERE length(t) > 1 AND t NOT IN
      ('md','do','np','pa','fnp','rn','dnp','phd','aprn','crnp','pmhnp','agnp','whnp',
       'msn','apn','bc','ii','iii','jr','sr','faap','facp','lcsw','psyd','arnp')
    ORDER BY t), ' '), '');
$$;

-- One row per admin decision, keyed on the normalized name. decision is
-- 'confirmed' (add + keep) or 'dismissed' (not a clinician). The loader reads the
-- confirmed set; the dismissed set is kept for provenance.
CREATE TABLE IF NOT EXISTS public.roster_decision (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_key text UNIQUE NOT NULL,
  canonical_name text,
  credential text,
  npi text,
  decision text NOT NULL DEFAULT 'confirmed',
  decided_by uuid,
  decided_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.roster_decision ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS roster_decision_sel ON public.roster_decision;
CREATE POLICY roster_decision_sel ON public.roster_decision FOR SELECT
  USING (public.is_active_app_user());
-- no write policy: rows are written only through set_roster_membership() (definer)

-- whoami(): the console calls this after sign-in to learn whether to show the
-- admin-only add-to-roster action. Reads the caller's own app_user row.
CREATE OR REPLACE FUNCTION public.whoami() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT jsonb_build_object('email', email, 'display_name', display_name, 'role', role,
    'is_admin', (role='admin' AND status='active'), 'active', (status='active'))
  FROM public.app_user WHERE auth_uid = auth.uid();
$$;

-- set_roster_membership(): admin-only. Records the decision (upsert on name_key)
-- and flips the roster row's status immediately, so the change shows at once and
-- also survives the next ingest.
CREATE OR REPLACE FUNCTION public.set_roster_membership(p_roster_id uuid, p_confirm boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.clinician_roster; nk text; newstatus text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only' USING errcode='42501'; END IF;
  SELECT * INTO r FROM public.clinician_roster WHERE id = p_roster_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'clinician not found' USING errcode='P0002'; END IF;
  nk := public.name_key(r.name);
  newstatus := CASE WHEN p_confirm THEN 'active' ELSE 'inactive' END;
  INSERT INTO public.roster_decision(name_key, canonical_name, credential, npi, decision, decided_by)
    VALUES (nk, r.name, r.credential, r.npi, CASE WHEN p_confirm THEN 'confirmed' ELSE 'dismissed' END, auth.uid())
    ON CONFLICT (name_key) DO UPDATE SET decision=EXCLUDED.decision, canonical_name=EXCLUDED.canonical_name,
      credential=EXCLUDED.credential, npi=EXCLUDED.npi, decided_by=EXCLUDED.decided_by, decided_at=now();
  UPDATE public.clinician_roster SET status = newstatus WHERE id = p_roster_id;
  PERFORM public.log_access('roster_decision', r.name || ' -> ' || newstatus);
  RETURN jsonb_build_object('id', p_roster_id, 'name', r.name, 'status', newstatus, 'name_key', nk);
END; $$;

REVOKE ALL ON FUNCTION public.whoami()                              FROM public;
REVOKE ALL ON FUNCTION public.set_roster_membership(uuid, boolean)  FROM public;
GRANT EXECUTE ON FUNCTION public.whoami()                              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_roster_membership(uuid, boolean)  TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- Ingest volume check: per-partner row counts captured at each load, so a load
-- can be compared to the one before it and a partner that vanished / appeared /
-- swung hard is flagged instead of silently loaded. Written by the loader with
-- the service-role key (bypasses RLS); readable by active app users.
CREATE TABLE IF NOT EXISTS public.ingest_partner_snapshot (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind text NOT NULL,
  partner text NOT NULL,
  n integer NOT NULL,
  source_upload_id uuid REFERENCES public.source_upload(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ingest_partner_snapshot_kind_time
  ON public.ingest_partner_snapshot (source_kind, created_at DESC);
ALTER TABLE public.ingest_partner_snapshot ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ips_sel ON public.ingest_partner_snapshot;
CREATE POLICY ips_sel ON public.ingest_partner_snapshot FOR SELECT
  USING (public.is_active_app_user());
