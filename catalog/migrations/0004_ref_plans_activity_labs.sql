-- =====================================================================
-- Atwater catalog · 0004 · reference: diet plans, activity types,
-- body/device metrics, lab analytes, open-standard ingest mappings
-- =====================================================================
BEGIN;

-- National guidelines, dietary patterns and weight-control plans share one
-- model: a versioned JSON rule document evaluated by the middleware
-- `targets` module. CI validates `rules` against the JSON Schema named by
-- rules_schema_version before a version can be published.
CREATE TABLE ref.diet_plan (
  plan_id         uuid PRIMARY KEY DEFAULT uuidv7(),
  slug            text NOT NULL UNIQUE,         -- 'us-myplate', 'uk-eatwell', 'dash', 'mediterranean', 'keto'
  kind            text NOT NULL CHECK (kind IN (
                    'national_guideline','dietary_pattern','weight_control','therapeutic')),
  authority_code  text REFERENCES ref.authority,
  region          text,
  name            text NOT NULL,
  description     text
);

CREATE TABLE ref.diet_plan_version (
  plan_version_id       uuid PRIMARY KEY DEFAULT uuidv7(),
  plan_id               uuid NOT NULL REFERENCES ref.diet_plan,
  version               int  NOT NULL CHECK (version > 0),
  rules                 jsonb NOT NULL CHECK (jsonb_typeof(rules) = 'object'),
  rules_schema_version  int  NOT NULL CHECK (rules_schema_version > 0),
  published_at          timestamptz NOT NULL DEFAULT now(),
  retired_at            timestamptz,
  UNIQUE (plan_id, version)
);

-- Compendium of Physical Activities (import the full adult table).
CREATE TABLE ref.activity_type (
  activity_code       text PRIMARY KEY,          -- Compendium activity code
  compendium_edition  text NOT NULL,             -- e.g. '2024-adult'
  major_heading       text NOT NULL,             -- 'running', 'walking', 'home activities'
  description         text NOT NULL,
  met                 numeric(5,2) NOT NULL CHECK (met > 0)
);

-- Anything measured on the body or by a device: weight, BP, steps, HR, sleep.
CREATE TABLE ref.metric (
  metric_code    text PRIMARY KEY,               -- body_mass, bp_systolic, steps, heart_rate ...
  name           text NOT NULL,
  unit_code      text NOT NULL REFERENCES ref.unit,   -- canonical storage unit
  value_kind     text NOT NULL CHECK (value_kind IN ('instant','interval_sum','interval_avg')),
  loinc_code     text,
  min_plausible  numeric,                        -- reject obvious unit mistakes at write time
  max_plausible  numeric,
  CHECK (min_plausible IS NULL OR max_plausible IS NULL OR min_plausible < max_plausible)
);

-- Lab analytes keyed by LOINC (LOINC content is free but requires accepting
-- its license; store the release used in ops docs).
CREATE TABLE ref.lab_analyte (
  loinc_code            text PRIMARY KEY CHECK (loinc_code ~ '^[0-9]{1,7}-[0-9]$'),
  name                  text NOT NULL,
  category              text NOT NULL CHECK (category IN (
                          'metabolic','lipid','hematology','vitamin','mineral','hormone',
                          'liver','kidney','inflammation','thyroid','other')),
  canonical_unit_code   text REFERENCES ref.unit,
  molar_mass_g_per_mol  numeric(12,4)
);

-- Analyte-specific conversions (mg/dL <-> mmol/L depends on the molecule).
CREATE TABLE ref.lab_unit_conversion (
  loinc_code      text NOT NULL REFERENCES ref.lab_analyte,
  from_unit_code  text NOT NULL REFERENCES ref.unit,
  to_unit_code    text NOT NULL REFERENCES ref.unit,
  factor          numeric(18,9) NOT NULL CHECK (factor > 0),   -- to = from * factor
  PRIMARY KEY (loinc_code, from_unit_code, to_unit_code),
  CHECK (from_unit_code <> to_unit_code)
);

-- ---------------------------------------------------------------------
-- Open-standard ingest mappings. Data, not code: adding a device type or
-- schema is a catalog insert, not an app release.
-- ---------------------------------------------------------------------

-- IEEE 1752 / Open mHealth schema -> metric. One schema can feed several
-- metrics (blood-pressure -> systolic + diastolic), so value_path says
-- where in the data point body the number lives.
CREATE TABLE ref.omh_schema_map (
  namespace       text NOT NULL CHECK (namespace IN ('omh','ieee')),
  schema_name     text NOT NULL CHECK (schema_name ~ '^[a-z0-9-]+$'),   -- 'heart-rate', 'step-count'
  metric_code     text NOT NULL REFERENCES ref.metric,
  value_path      text NOT NULL,                  -- JSON path in the body, e.g. '$.heart_rate.value'
  unit_path       text,                           -- JSON path to the unit string, when present
  min_version     text,                           -- earliest schema version accepted (NULL = any)
  PRIMARY KEY (namespace, schema_name, metric_code)
);

-- Bluetooth SIG GATT characteristic -> metric, for the mobile apps'
-- direct BLE sensor support. UUIDs are stored in full 128-bit form.
CREATE TABLE ref.ble_gatt_map (
  service_uuid         uuid NOT NULL,
  characteristic_uuid  uuid NOT NULL,
  metric_code          text NOT NULL REFERENCES ref.metric,
  field                text NOT NULL,             -- field of the characteristic, e.g. 'systolic'
  service_name         text NOT NULL,
  characteristic_name  text NOT NULL,
  PRIMARY KEY (characteristic_uuid, metric_code)
);

-- Expand a 16-bit SIG-assigned UUID ('2A37') to the full Bluetooth base UUID.
CREATE OR REPLACE FUNCTION ref.ble_uuid16(short_hex text) RETURNS uuid
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT ('0000' || lpad(lower(short_hex), 4, '0') || '-0000-1000-8000-00805f9b34fb')::uuid
$$;

COMMIT;
