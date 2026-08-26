-- ============================================================================
-- 32_service_line_abbrev.sql - short calendar codes for the coverage console
--
-- The coverage console (Gaps / Who's on / State coverage) shows a service line
-- as a compact badge and offers the coverage calendars as a checkable filter.
-- The entity names are long ("Daytime Clinical Service Line"); this adds an
-- admin-visible short code used for the badge, alongside a friendly name the
-- feed derives by stripping the boilerplate suffix. Additive and idempotent.
--
-- Only the on-demand coverage calendars (count_in_coverage=true) are seeded;
-- everything else is excluded from coverage math and never shows in the picker.
-- ============================================================================
alter table public.service_line_map add column if not exists abbrev text;

update public.service_line_map set abbrev = v.ab from (values
  ('Daytime Clinical Service Line','CSL'),
  ('Weight Management Service Line','WSL'),
  ('Wisp Schedule','Wisp'),
  ('HealthOme Program Schedule','HmL'),
  ('EZ Health','EZH'),
  ('Dynamic - Internal','Dyn'),
  ('Whoop CITL','Whoop')
) as v(entity, ab)
where service_line_map.entity = v.entity
  and (service_line_map.abbrev is null or service_line_map.abbrev = '');
