-- =====================================================================
-- Atwater tenant · 0004 · hydration, activity, body measurements,
-- high-frequency device samples, daily summary
-- =====================================================================
BEGIN;

-- Drinks not logged as food. Water inside logged foods/beverages is counted
-- from the food's water nutrient in the rollup, so nothing is double-counted.
CREATE TABLE usr.hydration_entry (
  user_id        uuid        NOT NULL,
  consumed_at    timestamptz NOT NULL,
  entry_id       uuid        NOT NULL,
  local_date     date        NOT NULL,
  tz             text        NOT NULL,
  beverage_kind  text        NOT NULL DEFAULT 'water' CHECK (beverage_kind IN (
                   'water','sparkling_water','coffee','tea','milk','juice','soda',
                   'sports_drink','electrolyte','alcohol','other')),
  volume_ml      numeric(8,1) NOT NULL CHECK (volume_ml > 0 AND volume_ml <= 5000),
  source_id      uuid NOT NULL,
  external_id    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  version        int NOT NULL DEFAULT 1,
  deleted_at     timestamptz,
  PRIMARY KEY (user_id, consumed_at, entry_id),
  FOREIGN KEY (user_id) REFERENCES usr.account ON DELETE CASCADE,
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source
) PARTITION BY RANGE (consumed_at);
CREATE INDEX hydration_by_day ON usr.hydration_entry (user_id, local_date) WHERE deleted_at IS NULL;
CREATE INDEX hydration_by_id  ON usr.hydration_entry (user_id, entry_id);
CREATE UNIQUE INDEX hydration_dedupe
  ON usr.hydration_entry (user_id, source_id, external_id, consumed_at) WHERE external_id IS NOT NULL;
CREATE TABLE usr.hydration_entry_default PARTITION OF usr.hydration_entry DEFAULT;

CREATE TABLE usr.activity_session (
  user_id            uuid        NOT NULL,
  started_at         timestamptz NOT NULL,
  session_id         uuid        NOT NULL,
  ended_at           timestamptz NOT NULL,
  local_date         date        NOT NULL,
  tz                 text        NOT NULL,
  activity_code      text        NOT NULL CHECK (activity_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),  -- [catalog ref.activity_type]
  distance_m         numeric(10,1) CHECK (distance_m >= 0),
  energy_kcal        numeric(8,1)  CHECK (energy_kcal >= 0),   -- active energy
  energy_method      text CHECK (energy_method IN ('device','met_estimate','user')),
  avg_hr             smallint CHECK (avg_hr BETWEEN 20 AND 250),
  max_hr             smallint CHECK (max_hr BETWEEN 20 AND 250),
  perceived_effort   smallint CHECK (perceived_effort BETWEEN 1 AND 10),
  note_enc           bytea,
  source_id          uuid NOT NULL,
  external_id        text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  version            int NOT NULL DEFAULT 1,
  deleted_at         timestamptz,
  PRIMARY KEY (user_id, started_at, session_id),
  FOREIGN KEY (user_id) REFERENCES usr.account ON DELETE CASCADE,
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source,
  CHECK (ended_at > started_at AND ended_at - started_at <= interval '48 hours'),
  CHECK (max_hr IS NULL OR avg_hr IS NULL OR max_hr >= avg_hr)
) PARTITION BY RANGE (started_at);
CREATE INDEX activity_by_day ON usr.activity_session (user_id, local_date) WHERE deleted_at IS NULL;
CREATE INDEX activity_by_id  ON usr.activity_session (user_id, session_id);
CREATE UNIQUE INDEX activity_dedupe
  ON usr.activity_session (user_id, source_id, external_id, started_at) WHERE external_id IS NOT NULL;
CREATE TABLE usr.activity_session_default PARTITION OF usr.activity_session DEFAULT;

-- Weight, body fat, waist, blood pressure, resting HR ... one metric per row.
-- Paired readings (systolic + diastolic) share a reading_group_id.
CREATE TABLE usr.body_measurement (
  user_id           uuid        NOT NULL,
  measured_at       timestamptz NOT NULL,
  measurement_id    uuid        NOT NULL,
  local_date        date        NOT NULL,
  metric_code       text        NOT NULL CHECK (metric_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),  -- [catalog ref.metric]
  value             numeric(12,4) NOT NULL,   -- as entered
  unit_code         text        NOT NULL,  -- [catalog ref.unit]
  value_canonical   numeric(12,4) NOT NULL,   -- in ref.metric.unit_code
  reading_group_id  uuid,
  source_id         uuid NOT NULL,
  external_id       text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           int NOT NULL DEFAULT 1,
  deleted_at        timestamptz,
  PRIMARY KEY (user_id, measured_at, measurement_id),
  FOREIGN KEY (user_id) REFERENCES usr.account ON DELETE CASCADE,
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source
) PARTITION BY RANGE (measured_at);
CREATE INDEX body_by_metric ON usr.body_measurement (user_id, metric_code, measured_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX body_by_id     ON usr.body_measurement (user_id, measurement_id);
CREATE UNIQUE INDEX body_dedupe
  ON usr.body_measurement (user_id, source_id, external_id, measured_at) WHERE external_id IS NOT NULL;
CREATE TABLE usr.body_measurement_default PARTITION OF usr.body_measurement DEFAULT;

-- High-frequency wearable data (reserved for phase 4). Daily partitions,
-- append-only, not synced through change_log; clients read aggregates.
CREATE TABLE usr.observation_sample (
  user_id      uuid        NOT NULL,
  observed_at  timestamptz NOT NULL,
  metric_code  text        NOT NULL CHECK (metric_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),  -- [catalog ref.metric]
  source_id    uuid        NOT NULL,
  value        double precision NOT NULL,
  interval_s   int CHECK (interval_s > 0),      -- for interval metrics (steps per minute)
  ingested_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, observed_at, metric_code, source_id),
  FOREIGN KEY (user_id) REFERENCES usr.account ON DELETE CASCADE,
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source
) PARTITION BY RANGE (observed_at);
CREATE TABLE usr.observation_sample_default PARTITION OF usr.observation_sample DEFAULT;

-- One row per user per local day; rebuilt by the rollup worker.
CREATE TABLE usr.daily_summary (
  user_id              uuid NOT NULL,
  local_date           date NOT NULL,
  energy_in_kcal       numeric(8,1),
  energy_active_kcal   numeric(8,1),
  energy_resting_kcal  numeric(8,1),
  water_total_ml       numeric(8,1),     -- beverages + water from food
  steps                int,
  active_minutes       int,
  computed_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, local_date)
) PARTITION BY RANGE (local_date);
CREATE TABLE usr.daily_summary_default PARTITION OF usr.daily_summary DEFAULT;

CREATE TRIGGER touch BEFORE UPDATE ON usr.hydration_entry FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.hydration_entry
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('hydration_entry','entry_id','consumed_at');

CREATE TRIGGER touch BEFORE UPDATE ON usr.activity_session FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.activity_session
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('activity_session','session_id','started_at');

CREATE TRIGGER touch BEFORE UPDATE ON usr.body_measurement FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.body_measurement
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('body_measurement','measurement_id','measured_at');

COMMIT;
