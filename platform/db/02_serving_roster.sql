-- ============================================================================
-- 02_serving_roster.sql
-- Denormalized serving table for the Clinicians console + raw-name provenance
-- on sli_response. Applied live to project eeszygextbqglayglvfm as migrations
-- `serving_roster_and_load_policies` and `revoke_temp_load_policies`.
--
-- Design: the normalized core (clinician / clinician_identifier in
-- 01_canonical_model.sql) is the source of truth. clinician_roster is a fast,
-- array-typed projection the UI can filter without joins. It is rebuilt by the
-- identity engine, never hand-edited.
-- ============================================================================

-- Preserve the raw clinician name on every SLI row so identity resolution can
-- attach clinician_id later without a re-import (flexibility principle: never
-- discard source data on the way into the canonical model).
ALTER TABLE public.sli_response ADD COLUMN IF NOT EXISTS clinician_name_raw text;

CREATE TABLE IF NOT EXISTS public.clinician_roster (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL,
  credential       text,
  npi              text,
  emails           text[] NOT NULL DEFAULT '{}',
  aliases          text[] NOT NULL DEFAULT '{}',
  license_states   text[] NOT NULL DEFAULT '{}',
  active_states    text[] NOT NULL DEFAULT '{}',
  programs         text[] NOT NULL DEFAULT '{}',
  partners         text[] NOT NULL DEFAULT '{}',
  modalities       text[] NOT NULL DEFAULT '{}',
  consult_count    integer NOT NULL DEFAULT 0,
  shift_hours      numeric NOT NULL DEFAULT 0,
  incentive_usd    numeric NOT NULL DEFAULT 0,
  last_active      date,
  status           text NOT NULL DEFAULT 'inactive',   -- active | inactive | ADD-TO-ROSTER
  source_upload_id uuid REFERENCES public.source_upload(id),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_roster_status   ON public.clinician_roster(status);
CREATE INDEX IF NOT EXISTS idx_roster_states   ON public.clinician_roster USING gin(license_states);
CREATE INDEX IF NOT EXISTS idx_roster_programs ON public.clinician_roster USING gin(programs);

ALTER TABLE public.clinician_roster ENABLE ROW LEVEL SECURITY;

-- Read gate: identical to the canonical tables — only provisioned, active app
-- users can read (deny-by-default; anon/unprovisioned get nothing).
DROP POLICY IF EXISTS clinician_roster_sel ON public.clinician_roster;
CREATE POLICY clinician_roster_sel ON public.clinician_roster
  FOR SELECT USING (public.is_active_app_user());

-- NOTE: bulk loads use TEMPORARY `tmp_load_*` INSERT policies granted to anon,
-- then immediately revoked (see migration revoke_temp_load_policies). Steady
-- state has no anon write path to these tables.
