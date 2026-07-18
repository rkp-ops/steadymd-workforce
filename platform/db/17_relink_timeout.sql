-- ============================================================================
-- 17_relink_timeout.sql
-- Applied live to project eeszygextbqglayglvfm as migration relink_statement_timeout.
--
-- relink_clinician_spine() re-anchors the clinician spine and rebuilds the weekly
-- ledger across ALL fact rows — the finalization step every ingest ends with. The
-- ingest Edge Function calls it over PostgREST, whose connection role
-- (`authenticator`) carries statement_timeout = 8s (and service_role has no
-- override, so SET ROLE keeps the 8s). A full monthly load re-attributes 100k+ SLI
-- rows, which takes longer than 8s, so Postgres cancelled it (SQLSTATE 57014) and
-- the browser saw "Edge Function returned a non-2xx status code" — a false failure,
-- because the sli/incentive rows had already committed before this step ran.
--
-- A function-scoped statement_timeout lets the finalization run to completion
-- regardless of the caller's short default. Direct SQL (no 8s cap) already ran it
-- fine; this makes the Edge-Function path match. 120s is a generous ceiling — the
-- real runtime is a few seconds — well under the isolate's wall-clock.
-- ============================================================================

alter function public.relink_clinician_spine() set statement_timeout = '120s';
