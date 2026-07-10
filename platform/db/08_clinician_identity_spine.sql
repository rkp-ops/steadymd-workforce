-- ============================================================================
-- 08_clinician_identity_spine.sql
-- The stable identity spine. A durable `clinician` entity plus a key table that
-- maps every identity token (email / NPI / normalized name) to it, so a monthly
-- reload RE-LINKS a person to the same id instead of minting a new one. This is
-- the anchor the metric time-series (09) keys on, so a clinician's history never
-- forks when an email changes or the roster is rebuilt.
--
-- `clinician` already existed (from the canonical-model migration) but was never
-- populated — it becomes the source of truth for identity. `clinician_roster`
-- stays the denormalized, rebuilt-every-load console table, now carrying a
-- clinician_id link back to the stable entity. Fact tables get their (previously
-- always-null) clinician FKs filled by email, which covers ~100% of consults and
-- 99.3% of shifts (validated 2026-07-10).
--
-- Idempotent: safe to re-run. Attribution is additive (only fills NULLs).
-- ============================================================================

-- 1. Identity key lookup ------------------------------------------------------
create table if not exists public.clinician_key (
  key_type     text not null check (key_type in ('npi','email','name_key')),
  key_value    text not null,
  clinician_id uuid not null references public.clinician(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (key_type, key_value)
);
create index if not exists clinician_key_cid on public.clinician_key(clinician_id);
alter table public.clinician_key enable row level security;
-- No anon/authenticated policy on purpose: read only through SECURITY DEFINER RPCs.

-- 2. Roster -> stable entity link, and fact-table attribution indexes ---------
alter table public.clinician_roster add column if not exists clinician_id uuid references public.clinician(id);
create index if not exists clinician_roster_cid on public.clinician_roster(clinician_id);
create index if not exists consult_prim_cid on public.consult(primary_clinician_id);
create index if not exists shift_cid         on public.shift(clinician_id);
create index if not exists sli_cid           on public.sli_response(clinician_id);
create index if not exists incentive_cid     on public.incentive(clinician_id);

-- 3. Bootstrap one durable entity per current roster clinician ----------------
-- Future loads MATCH into these via clinician_key (see the ingestion change)
-- instead of creating duplicates, so ids stay stable across the monthly reload.
with newids as (
  update public.clinician_roster r
     set clinician_id = gen_random_uuid()
   where r.clinician_id is null
  returning r.clinician_id, r.name, r.credential, r.npi, r.status, r.last_active
)
insert into public.clinician (id, canonical_name, credential, primary_npi, status, first_seen, last_active)
select clinician_id, name, credential, nullif(npi,''), status, last_active, last_active
from newids
on conflict (id) do nothing;

-- 4. Populate the identity keys from the resolved roster ----------------------
insert into public.clinician_key (key_type, key_value, clinician_id)
select 'email', lower(e), r.clinician_id
from public.clinician_roster r, unnest(r.emails) e
where r.clinician_id is not null and e is not null and e <> ''
on conflict (key_type, key_value) do nothing;

insert into public.clinician_key (key_type, key_value, clinician_id)
select 'npi', r.npi, r.clinician_id
from public.clinician_roster r
where r.clinician_id is not null and nullif(r.npi,'') is not null
on conflict (key_type, key_value) do nothing;

insert into public.clinician_key (key_type, key_value, clinician_id)
select distinct 'name_key', public.name_key(a), r.clinician_id
from public.clinician_roster r, unnest(coalesce(r.aliases,'{}') || array[r.name]) a
where r.clinician_id is not null and public.name_key(a) <> ''
on conflict (key_type, key_value) do nothing;

-- 5. Backfill row-level attribution on the fact tables ------------------------
-- Consults & shifts by email (indexed join on the clinician_key PK -> light).
update public.consult c set primary_clinician_id = k.clinician_id
from public.clinician_key k
where k.key_type = 'email' and k.key_value = lower(nullif(c.clinician_email_raw,''))
  and c.primary_clinician_id is null;

update public.shift s set clinician_id = k.clinician_id
from public.clinician_key k
where k.key_type = 'email' and k.key_value = lower(nullif(s.clinician_email_raw,''))
  and s.clinician_id is null;

-- Shift residual (no email match) by normalized name — tiny set.
update public.shift s set clinician_id = k.clinician_id
from public.clinician_key k
where k.key_type = 'name_key' and k.key_value = public.name_key(s.clinician_name_raw)
  and s.clinician_id is null and public.name_key(s.clinician_name_raw) <> '';

-- SLIs inherit their consult's clinician (an SLI has no email of its own).
update public.sli_response sr set clinician_id = c.primary_clinician_id
from public.consult c
where c.consult_guid = sr.consult_guid
  and sr.clinician_id is null and c.primary_clinician_id is not null;

-- Incentives by email.
update public.incentive i set clinician_id = k.clinician_id
from public.clinician_key k
where k.key_type = 'email' and k.key_value = lower(nullif(i.clinician_email_raw,''))
  and i.clinician_id is null;
