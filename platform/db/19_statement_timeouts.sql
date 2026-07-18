-- ============================================================================
-- 19_statement_timeouts.sql
-- Applied live to project eeszygextbqglayglvfm as migration role_statement_timeouts.
--
-- CORRECTS 17 and 18. Those set statement_timeout on the FUNCTIONS
-- (relink_clinician_spine, sli_dataset) — which does nothing for a PostgREST call:
-- the per-request timeout timer is armed at the REQUEST ROLE's value BEFORE the
-- function is entered, and a function-scoped SET can't re-arm an already-running
-- statement's timer (verified: a function with SET statement_timeout='30s' is still
-- cancelled at a 1s session cap).
--
-- The real lever is the request role. Supabase's PostgREST applies the request
-- role's statement_timeout per request — which is why anon=3s and authenticated=8s
-- differ even though both tunnel through the `authenticator` login role.
--
--   * authenticated -> 30s: the console's sli_dataset() builds a ~120k-element
--     array (~5s, past the 8s default) so sign-in data-load was cancelled and the
--     whole console went dark. TEMPORARY — the durable fix is to have sli_dataset()
--     return a compact server-side aggregate instead of one row per SLI, after
--     which this can go back to 8s.
--   * service_role  -> 120s: the ingest Edge Function's relink_clinician_spine()
--     re-attributes 100k+ fact rows over PostgREST as service_role — legitimately
--     longer than 8s. (Direct SQL has no such cap, which is why it ran there.)
-- ============================================================================

alter role authenticated set statement_timeout = '30s';
alter role service_role  set statement_timeout = '120s';

-- undo the ineffective function-scoped attempts from 17 & 18 (role level is the lever)
alter function public.relink_clinician_spine() reset statement_timeout;
alter function public.sli_dataset()            reset statement_timeout;

-- nudge PostgREST to pick up the changed role settings immediately
notify pgrst, 'reload config';
