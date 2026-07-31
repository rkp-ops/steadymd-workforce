-- ============================================================================
-- 28_staffing_entities.sql — calendar provenance for the staffing view
--
-- "Is this actually just CSL?" must be answerable on screen, not taken on trust.
-- Returns every shift calendar (entity) present in the chosen window under the
-- SAME supply filters staffing_coverage uses, with whether it was counted and,
-- when it wasn't, the reason (staffing-only / support-routing / tracked-only /
-- siloed / not selected / unmapped).
-- ============================================================================
(definition applied live as migration staffing_entities)
