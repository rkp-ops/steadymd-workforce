-- ============================================================================
-- SteadyMD Workforce Platform — Canonical Data Model  (build 01)
-- The stable core the whole platform sits on. Source files are messy and vary;
-- everything normalizes INTO this, so analysis never touches raw file shape.
-- Design rules:
--   * GUIDs are gold. consult_guid + clinician_guid are first-class keys.
--   * A clinician is ONE entity with MANY identifiers (npi/email/guid/name).
--   * Nothing is destructive: every row carries source_upload provenance.
--   * "worked" is config, not hard-coded (see meaningful_status).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Provenance — every ingested file, so any number is traceable & reversible
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS source_upload (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind   TEXT NOT NULL,              -- 'sli' | 'metabase_touch' | 'aria_shift' | 'license_detail' | 'roster' | 'incentive' | ...
  source_profile_id UUID,                   -- resolved ingestion profile (below)
  filename      TEXT,
  content_sha256 TEXT,                      -- dedupe identical re-uploads
  row_count     INTEGER,
  period_start  DATE,
  period_end    DATE,
  uploaded_by   UUID,                       -- app_user.id
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw_headers   JSONB,                      -- exact columns as received (for audit)
  notes         TEXT
);

-- ---------------------------------------------------------------------------
-- 1. Clinician identity — one entity, many keys (the reliability backbone)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clinician (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name TEXT NOT NULL,
  credential     TEXT,                      -- MD/DO/NP/PA/... (best-known)
  primary_npi    TEXT,
  employment_type TEXT,
  status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  first_seen     DATE,
  last_active    DATE,                      -- max activity across all sources
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Every identifier we've ever seen for a clinician. This is what makes name
-- variance (Last,First vs first last vs hyphen-drop) never break a join.
CREATE TABLE IF NOT EXISTS clinician_identifier (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id UUID NOT NULL REFERENCES clinician(id) ON DELETE CASCADE,
  id_type      TEXT NOT NULL CHECK (id_type IN ('npi','email','clinician_guid','name_norm')),
  id_value     TEXT NOT NULL,               -- normalized (lower email, sorted name tokens, etc.)
  raw_value    TEXT,                        -- exactly as seen in the file
  source_kind  TEXT,
  confidence   NUMERIC NOT NULL DEFAULT 1.0,
  first_seen   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- A strong key can only belong to one clinician; a name_norm can be shared,
-- so it is NOT globally unique (resolution handles collisions).
CREATE UNIQUE INDEX IF NOT EXISTS uq_clin_ident_strong
  ON clinician_identifier (id_type, id_value)
  WHERE id_type IN ('npi','email','clinician_guid');
CREATE INDEX IF NOT EXISTS idx_clin_ident_value ON clinician_identifier (id_type, id_value);
CREATE INDEX IF NOT EXISTS idx_clin_ident_clin  ON clinician_identifier (clinician_id);

-- State licensure (from license detail + roster) → drives State Coverage.
CREATE TABLE IF NOT EXISTS clinician_license (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id  UUID NOT NULL REFERENCES clinician(id) ON DELETE CASCADE,
  state         TEXT NOT NULL,
  license_type  TEXT,
  license_number TEXT,
  status        TEXT,                       -- Active / Clear-to-Practice / etc.
  expiration_date DATE,
  source_upload_id UUID REFERENCES source_upload(id),
  UNIQUE (clinician_id, state, license_number)
);
CREATE INDEX IF NOT EXISTS idx_clin_license_state ON clinician_license (state);

-- Clinicians seen in activity but not yet confidently on the roster, or names
-- that resolve ambiguously → surfaced in the UI for one-click confirm/add.
CREATE TABLE IF NOT EXISTS identity_review_queue (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_name      TEXT,
  raw_source    TEXT,
  reason        TEXT CHECK (reason IN ('new_clinician','ambiguous_name','key_conflict')),
  candidate_clinician_id UUID REFERENCES clinician(id),
  evidence      JSONB,
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','dismissed')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- 2. Consults — de-duped to ONE row per consult_guid (touches roll up here)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS consult (
  consult_guid    TEXT PRIMARY KEY,
  partner         TEXT,
  program         TEXT,
  service_line    TEXT,
  consult_type    TEXT,                     -- raw token, e.g. chart_review, video_chat
  modality_class  TEXT,                     -- sync | async | cv (resolved from consult_type)
  reason_for_visit TEXT,                    -- follow-up / side effect / rx change (Looker/Metabase)
  is_return       BOOLEAN,                  -- net-new vs returning
  created_at      TIMESTAMPTZ,
  first_worked_at TIMESTAMPTZ,              -- first meaningful-status touch
  final_status    TEXT,
  final_status_at TIMESTAMPTZ,
  primary_clinician_id UUID REFERENCES clinician(id),
  n_touches       INTEGER,
  n_worked_touches INTEGER,
  handle_seconds  BIGINT,                   -- derived from status timings
  source_upload_id UUID REFERENCES source_upload(id)
);
CREATE INDEX IF NOT EXISTS idx_consult_partner ON consult (partner, created_at);
CREATE INDEX IF NOT EXISTS idx_consult_clin    ON consult (primary_clinician_id);

-- Atomic status transitions (the Metabase touch-by-touch file). Many per consult.
CREATE TABLE IF NOT EXISTS consult_touch (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  consult_guid  TEXT NOT NULL,
  status_id     TEXT NOT NULL,              -- in_progress, in_call, waiting, completed, lab_*...
  status_at     TIMESTAMPTZ NOT NULL,
  clinician_id  UUID REFERENCES clinician(id),
  clinician_guid TEXT,
  source_upload_id UUID REFERENCES source_upload(id)
);
CREATE INDEX IF NOT EXISTS idx_touch_consult ON consult_touch (consult_guid, status_at);
CREATE INDEX IF NOT EXISTS idx_touch_clin    ON consult_touch (clinician_id, status_at);

-- Config: which statuses count as "worked / moved care forward" (NOT hard-coded).
-- Everything else (passive/system statuses) is excluded from performance metrics.
CREATE TABLE IF NOT EXISTS meaningful_status (
  status_id   TEXT PRIMARY KEY,
  counts_as_worked BOOLEAN NOT NULL DEFAULT TRUE,
  is_patient_facing BOOLEAN NOT NULL DEFAULT FALSE,   -- in_call etc. (time-with-patient)
  is_terminal BOOLEAN NOT NULL DEFAULT FALSE,
  notes       TEXT
);

-- ---------------------------------------------------------------------------
-- 3. SLI (service-level) — the Completed-vs-Due source; SLA computed, not trusted
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sli_response (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  consult_guid  TEXT,
  clinician_id  UUID REFERENCES clinician(id),
  partner       TEXT,
  program       TEXT,
  state         TEXT,
  consult_type  TEXT,
  sli_received  TIMESTAMPTZ,
  sli_due       TIMESTAMPTZ,
  sli_completed TIMESTAMPTZ,
  sli_status_raw TEXT,                      -- kept only as a cross-check fixture
  during_biz_hrs BOOLEAN,
  wait_seconds  BIGINT GENERATED ALWAYS AS   -- Rec -> Completed, for wait metrics
    (EXTRACT(EPOCH FROM (sli_completed - sli_received))::BIGINT) STORED,
  sla_met       BOOLEAN GENERATED ALWAYS AS  -- THE method: Completed <= Due
    (CASE WHEN sli_completed IS NOT NULL AND sli_due IS NOT NULL
          THEN sli_completed <= sli_due END) STORED,
  source_upload_id UUID REFERENCES source_upload(id)
);
CREATE INDEX IF NOT EXISTS idx_sli_partner ON sli_response (partner, sli_received);
CREATE INDEX IF NOT EXISTS idx_sli_state   ON sli_response (state, sli_received);
CREATE INDEX IF NOT EXISTS idx_sli_consult ON sli_response (consult_guid);

-- ---------------------------------------------------------------------------
-- 4. Shifts (Aria) and Incentives
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shift (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id  UUID REFERENCES clinician(id),
  shift_type    TEXT,
  service_line  TEXT,                       -- from Aria "Entity Name"
  start_at      TIMESTAMPTZ,
  end_at        TIMESTAMPTZ,
  hours         NUMERIC,
  source_upload_id UUID REFERENCES source_upload(id)
);
CREATE INDEX IF NOT EXISTS idx_shift_clin ON shift (clinician_id, start_at);

CREATE TABLE IF NOT EXISTS incentive (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  consult_guid  TEXT,
  clinician_id  UUID REFERENCES clinician(id),
  partner       TEXT,
  program       TEXT,
  state         TEXT,
  consult_type  TEXT,
  launched_at   TIMESTAMPTZ,
  amount_cents  BIGINT,                     -- store money as integer cents
  currency      TEXT DEFAULT 'USD',
  incentive_name TEXT,
  budget_name   TEXT,
  source_upload_id UUID REFERENCES source_upload(id)
);
CREATE INDEX IF NOT EXISTS idx_incentive_consult ON incentive (consult_guid);
CREATE INDEX IF NOT EXISTS idx_incentive_launch  ON incentive (launched_at);

-- ---------------------------------------------------------------------------
-- 5. Flexible ingestion registry — how varied files map to the canonical model
--    (fuzzy header match + confirm-once-remember). This is the anti-rigidity core.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS source_profile (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,              -- 'Metabase touch export', 'Aria shifts', ...
  source_kind   TEXT NOT NULL,
  fingerprint   JSONB NOT NULL,             -- characteristic column set for content-based detection
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS column_mapping (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_profile_id UUID NOT NULL REFERENCES source_profile(id) ON DELETE CASCADE,
  canonical_field  TEXT NOT NULL,           -- e.g. 'sli_completed'
  source_header    TEXT NOT NULL,           -- e.g. 'SLI Completed'
  confidence       NUMERIC NOT NULL DEFAULT 1.0,
  confirmed_by     UUID,                    -- app_user.id (null = auto)
  confirmed_at     TIMESTAMPTZ,
  UNIQUE (source_profile_id, canonical_field)
);

-- ---------------------------------------------------------------------------
-- 6. Self-documenting: metric registry (feeds the Methodology tab + tooltips)
--    and auto-tracked data gaps/callouts (e.g. "1 GUID = 49.8% of touches").
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS metric_definition (
  key         TEXT PRIMARY KEY,            -- 'sla_met', 'consults_worked', 'avg_handle', ...
  label       TEXT NOT NULL,
  short_hint  TEXT,                        -- tooltip text
  formula     TEXT,                        -- human-readable + the actual method
  method_note TEXT,
  source_fields TEXT[],
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS data_gap_flag (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        TEXT NOT NULL,               -- 'attribution_skew','unrostered_clinician','missing_column',...
  severity    TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warn','critical')),
  detail      TEXT NOT NULL,
  evidence    JSONB,
  source_upload_id UUID REFERENCES source_upload(id),
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','ack','resolved')),
  first_seen  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- 7. Seed the first two auto-tracked findings from today's real-data run
-- ---------------------------------------------------------------------------
INSERT INTO data_gap_flag (kind, severity, detail, evidence) VALUES
  ('attribution_skew','warn',
   'One clinician_guid accounts for 49.8% of all consult touches in the Metabase export — almost certainly a supervisor/auto attribution, not worked volume. "consults touched" must use meaningful_status to be a real performance metric.',
   '{"clinician":"Joshua Emdur, DO","distinct_consults":87821,"pct_of_all":49.8,"total_consults":176521}'::jsonb),
  ('unrostered_clinician','info',
   '24 clinicians appear in activity but are not on the curated roster yet (the "always being added" case). Surfaced for one-click add.',
   '{"count":24,"examples":["Barrett-Powell, Avia","Tang, Sandy","Dhuka, Faizmeen"]}'::jsonb);
