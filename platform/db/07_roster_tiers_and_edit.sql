-- ============================================================================
-- 07_roster_tiers_and_edit.sql
-- Capacity tiers, the needs-correction queue, and admin roster editing.
-- Applied live to project eeszygextbqglayglvfm as migration roster_tiers_and_edit.
--
-- Two things drove this: (1) support staff (Medical Assistants) were being counted
-- like prescribers, and (2) the roster was locked to add-only — no way to fix a
-- missing credential/state or remove someone. Now:
--   * every clinician is tiered — seat (MD/DO/PA + the NP/APRN family, who can own
--     a full seat) vs support (MA/RN/etc., who touch consults but never count toward
--     coverage). MA is support by definition.
--   * anyone missing a credential, or a seat clinician missing a state license, is
--     pulled into a NEEDS-CORRECTION queue instead of sitting in the active list.
--   * admins can set a credential, set states, or remove a clinician; the edit is
--     remembered in roster_decision so a data refresh keeps it (see 06_identity_memory).
-- roster_tier() mirrors identity_lib._tier() so the loader and the DB agree.
-- ============================================================================

ALTER TABLE public.clinician_roster ADD COLUMN IF NOT EXISTS tier text;              -- 'seat' | 'support' | null
ALTER TABLE public.clinician_roster ADD COLUMN IF NOT EXISTS needs text[] NOT NULL DEFAULT '{}';  -- e.g. {credential,state}
ALTER TABLE public.roster_decision  ADD COLUMN IF NOT EXISTS states text[];           -- admin state override

CREATE OR REPLACE FUNCTION public.roster_tier(cred text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN cred IS NULL OR btrim(cred) = '' THEN NULL
    WHEN upper(regexp_replace(cred, '[-.]', '', 'g')) IN ('MD','DO','PA')
      OR upper(cred) LIKE '%NP%' OR upper(cred) LIKE '%APRN%' OR upper(cred) LIKE '%ARNP%'
      OR upper(cred) LIKE '%CRNP%' OR upper(cred) LIKE '%DNP%'
      OR upper(regexp_replace(cred, '[-.]', '', 'g')) IN ('APN','APNP') THEN 'seat'
    ELSE 'support' END;
$$;

-- recompute tier / needs / status for one row after a credential or states change
CREATE OR REPLACE FUNCTION public.roster_reclassify(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.clinician_roster; t text; nds text[] := '{}'; refd date; act boolean;
BEGIN
  SELECT * INTO r FROM public.clinician_roster WHERE id = p_id;
  IF NOT FOUND THEN RETURN; END IF;
  t := public.roster_tier(r.credential);
  IF r.credential IS NULL OR btrim(r.credential) = '' THEN nds := nds || 'credential'; END IF;
  IF t = 'seat' AND coalesce(array_length(r.license_states,1),0) = 0 THEN nds := nds || 'state'; END IF;
  SELECT max(last_active) INTO refd FROM public.clinician_roster;   -- proxy for the export "today"
  act := r.last_active IS NOT NULL AND r.last_active >= refd - 90;
  UPDATE public.clinician_roster SET tier = t, needs = nds,
    status = CASE WHEN array_length(nds,1) > 0 THEN 'NEEDS-CORRECTION'
                  WHEN act THEN 'active' ELSE 'inactive' END
  WHERE id = p_id;
END; $$;

-- admin edit: set credential and/or states, or remove. States are replaced by the
-- set passed in. Remembered in roster_decision so a refresh keeps the correction.
CREATE OR REPLACE FUNCTION public.edit_clinician(p_roster_id uuid, p_credential text, p_states text[], p_remove boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.clinician_roster; nk text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'admin only' USING errcode='42501'; END IF;
  SELECT * INTO r FROM public.clinician_roster WHERE id = p_roster_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'clinician not found' USING errcode='P0002'; END IF;
  nk := public.name_key(r.name);
  IF coalesce(p_remove, false) THEN
    INSERT INTO public.roster_decision(name_key, canonical_name, credential, npi, decision, decided_by)
      VALUES (nk, r.name, r.credential, r.npi, 'dismissed', auth.uid())
      ON CONFLICT (name_key) DO UPDATE SET decision='dismissed', decided_by=auth.uid(), decided_at=now();
    DELETE FROM public.clinician_roster WHERE id = p_roster_id;
    PERFORM public.log_access('roster_edit', r.name || ' -> removed');
    RETURN jsonb_build_object('id', p_roster_id, 'removed', true, 'name', r.name);
  END IF;
  INSERT INTO public.roster_decision(name_key, canonical_name, credential, npi, states, decision, decided_by)
    VALUES (nk, r.name, coalesce(p_credential, r.credential), r.npi, p_states, 'confirmed', auth.uid())
    ON CONFLICT (name_key) DO UPDATE SET
      credential = coalesce(EXCLUDED.credential, roster_decision.credential),
      states = coalesce(EXCLUDED.states, roster_decision.states),
      decision = 'confirmed', decided_by = auth.uid(), decided_at = now();
  UPDATE public.clinician_roster SET
    credential = coalesce(p_credential, credential),
    license_states = coalesce(p_states, license_states)
  WHERE id = p_roster_id;
  PERFORM public.roster_reclassify(p_roster_id);
  SELECT * INTO r FROM public.clinician_roster WHERE id = p_roster_id;
  PERFORM public.log_access('roster_edit', r.name);
  RETURN jsonb_build_object('id', p_roster_id, 'name', r.name, 'credential', r.credential,
    'tier', r.tier, 'license_states', to_jsonb(r.license_states), 'needs', to_jsonb(r.needs), 'status', r.status);
END; $$;

REVOKE ALL ON FUNCTION public.edit_clinician(uuid, text, text[], boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.edit_clinician(uuid, text, text[], boolean) TO anon, authenticated;
