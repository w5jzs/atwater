-- =====================================================================
-- Atwater tenant · 0003 · nutrition: custom foods & recipes, food log,
-- diet plans, target overrides, resolved daily targets, rollups
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- Custom foods and recipes (user-owned). Same pattern as ref foods:
-- a mutable header + immutable versions that log entries point at.
-- ---------------------------------------------------------------------
CREATE TABLE usr.custom_food (
  user_id             uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  custom_food_id      uuid NOT NULL,
  kind                text NOT NULL CHECK (kind IN ('food','recipe','meal')),
  name                text NOT NULL,
  current_version_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  version             int NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  PRIMARY KEY (user_id, custom_food_id)
);

CREATE TABLE usr.custom_food_version (           -- immutable
  user_id                 uuid NOT NULL,
  custom_food_version_id  uuid NOT NULL,
  custom_food_id          uuid NOT NULL,
  version                 int  NOT NULL CHECK (version > 0),
  nutrient_basis          text NOT NULL DEFAULT 'per_100g' CHECK (nutrient_basis IN ('per_100g','per_100ml')),
  yield_grams             numeric(10,3) CHECK (yield_grams > 0),   -- recipes: finished weight
  servings                numeric(8,3)  CHECK (servings > 0),
  density_g_per_ml        numeric(8,4)  CHECK (density_g_per_ml > 0),
  created_at              timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, custom_food_version_id),
  UNIQUE (user_id, custom_food_id, version),
  FOREIGN KEY (user_id, custom_food_id) REFERENCES usr.custom_food ON DELETE CASCADE
);

ALTER TABLE usr.custom_food
  ADD FOREIGN KEY (user_id, current_version_id)
  REFERENCES usr.custom_food_version (user_id, custom_food_version_id)
  DEFERRABLE INITIALLY DEFERRED;

-- Nutrient vector per 100 g/mL. For recipes this is computed from the
-- ingredients (with yield/cooking loss) when the version is created.
CREATE TABLE usr.custom_food_nutrient (           -- immutable
  user_id                 uuid     NOT NULL,
  custom_food_version_id  uuid     NOT NULL,
  nutrient_id             smallint NOT NULL CHECK (nutrient_id > 0),  -- [catalog ref.nutrient]
  amount                  numeric(14,6) NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (user_id, custom_food_version_id, nutrient_id),
  FOREIGN KEY (user_id, custom_food_version_id) REFERENCES usr.custom_food_version ON DELETE CASCADE
);

CREATE TABLE usr.recipe_ingredient (              -- immutable
  user_id                       uuid     NOT NULL,
  custom_food_version_id        uuid     NOT NULL,   -- the recipe version
  line_no                       smallint NOT NULL CHECK (line_no > 0),
  food_version_id               uuid,  -- [catalog ref.food_version]
  ingredient_custom_version_id  uuid,                -- nested recipe or custom food
  quantity                      numeric(10,3) NOT NULL CHECK (quantity > 0),
  portion_id                    uuid,  -- [catalog ref.food_portion]
  unit_code                     text,  -- [catalog ref.unit]
  grams                         numeric(10,3) NOT NULL CHECK (grams > 0),   -- normalized at write
  PRIMARY KEY (user_id, custom_food_version_id, line_no),
  FOREIGN KEY (user_id, custom_food_version_id) REFERENCES usr.custom_food_version ON DELETE CASCADE,
  FOREIGN KEY (user_id, ingredient_custom_version_id) REFERENCES usr.custom_food_version (user_id, custom_food_version_id),
  CHECK (num_nonnulls(food_version_id, ingredient_custom_version_id) = 1),
  CHECK (ingredient_custom_version_id IS DISTINCT FROM custom_food_version_id)
);

-- ---------------------------------------------------------------------
-- Food log (hot path). Monthly partitions on consumed_at via pg_partman.
-- ---------------------------------------------------------------------
CREATE TABLE usr.food_log_entry (
  user_id                 uuid        NOT NULL,
  consumed_at             timestamptz NOT NULL,
  entry_id                uuid        NOT NULL,     -- client-generated UUIDv7 (idempotent sync)
  local_date              date        NOT NULL,     -- in the user's zone at entry time
  tz                      text        NOT NULL,
  meal_slot               text CHECK (meal_slot IN ('breakfast','lunch','dinner','snack','other')),
  food_version_id         uuid,  -- [catalog ref.food_version]
  custom_food_version_id  uuid,
  quantity                numeric(10,3) NOT NULL CHECK (quantity > 0),
  portion_id              uuid,  -- [catalog ref.food_portion]
  unit_code               text,  -- [catalog ref.unit]
  grams                   numeric(10,3) NOT NULL CHECK (grams > 0 AND grams <= 20000),
  note_enc                bytea,                    -- encrypted with the user's DEK
  source_id               uuid NOT NULL,
  external_id             text,                     -- dedupe key from imports/devices
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  version                 int NOT NULL DEFAULT 1,
  deleted_at              timestamptz,              -- tombstone for sync
  PRIMARY KEY (user_id, consumed_at, entry_id),
  FOREIGN KEY (user_id) REFERENCES usr.account ON DELETE CASCADE,
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source,
  FOREIGN KEY (user_id, custom_food_version_id) REFERENCES usr.custom_food_version (user_id, custom_food_version_id),
  CHECK (num_nonnulls(food_version_id, custom_food_version_id) = 1),
  CHECK (portion_id IS NULL OR food_version_id IS NOT NULL)
) PARTITION BY RANGE (consumed_at);

CREATE INDEX food_log_by_day   ON usr.food_log_entry (user_id, local_date) WHERE deleted_at IS NULL;
CREATE INDEX food_log_by_id    ON usr.food_log_entry (user_id, entry_id);
CREATE INDEX food_log_brin     ON usr.food_log_entry USING brin (consumed_at);
CREATE UNIQUE INDEX food_log_dedupe
  ON usr.food_log_entry (user_id, source_id, external_id, consumed_at) WHERE external_id IS NOT NULL;
CREATE TABLE usr.food_log_entry_default PARTITION OF usr.food_log_entry DEFAULT;

-- ---------------------------------------------------------------------
-- Diet plans: user clones of ref plans are immutable versions too.
-- ---------------------------------------------------------------------
CREATE TABLE usr.custom_plan_version (            -- immutable
  user_id                   uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  custom_plan_version_id    uuid NOT NULL,
  custom_plan_id            uuid NOT NULL,          -- groups versions of one plan
  version                   int  NOT NULL CHECK (version > 0),
  name                      text NOT NULL,
  based_on_plan_version_id  uuid,  -- [catalog ref.diet_plan_version]
  rules                     jsonb NOT NULL CHECK (jsonb_typeof(rules) = 'object'),
  rules_schema_version      int  NOT NULL CHECK (rules_schema_version > 0),
  created_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, custom_plan_version_id),
  UNIQUE (user_id, custom_plan_id, version)
);

-- Which plan is active when. Daterange on local dates; one at a time.
CREATE TABLE usr.plan_assignment (
  user_id                 uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  assignment_id           uuid NOT NULL,
  plan_version_id         uuid,  -- [catalog ref.diet_plan_version]
  custom_plan_version_id  uuid,
  energy_adjust_kcal      int CHECK (energy_adjust_kcal BETWEEN -1500 AND 1500),  -- planned deficit (<0) or surplus
  valid                   daterange NOT NULL CHECK (NOT isempty(valid)),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  version                 int NOT NULL DEFAULT 1,
  deleted_at              timestamptz,
  PRIMARY KEY (user_id, assignment_id),
  FOREIGN KEY (user_id, custom_plan_version_id) REFERENCES usr.custom_plan_version,
  CHECK (num_nonnulls(plan_version_id, custom_plan_version_id) = 1),
  EXCLUDE USING gist (user_id WITH =, valid WITH &&) WHERE (deleted_at IS NULL)
);

-- Personal or clinician overrides; clinician beats user beats plan beats authority.
CREATE TABLE usr.target_override (
  user_id      uuid     NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  override_id  uuid     NOT NULL,
  nutrient_id  smallint NOT NULL CHECK (nutrient_id > 0),  -- [catalog ref.nutrient]
  basis        text     NOT NULL DEFAULT 'per_day' CHECK (basis IN (
                 'per_day','pct_energy','per_kg_body_weight','per_1000_kcal')),
  amount_low   numeric(14,6),
  amount_high  numeric(14,6),
  set_by       text NOT NULL CHECK (set_by IN ('user','clinician')),
  reason_enc   bytea,
  valid        daterange NOT NULL CHECK (NOT isempty(valid)),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  version      int NOT NULL DEFAULT 1,
  deleted_at   timestamptz,
  PRIMARY KEY (user_id, override_id),
  CHECK (amount_low IS NOT NULL OR amount_high IS NOT NULL),
  CHECK (amount_low IS NULL OR amount_high IS NULL OR amount_low <= amount_high),
  EXCLUDE USING gist (user_id WITH =, nutrient_id WITH =, set_by WITH =, valid WITH &&)
    WHERE (deleted_at IS NULL)
);

-- ---------------------------------------------------------------------
-- Resolved targets (materialized so history is judged against the targets
-- in force that day). Most days share inputs, so provenance is stored once
-- per distinct resolution and referenced.
-- ---------------------------------------------------------------------
CREATE TABLE usr.target_resolution (
  user_id        uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  resolution_id  uuid NOT NULL,
  inputs         jsonb NOT NULL,      -- authority+edition, life_stage_code, plan version, override ids, body mass used
  inputs_hash    bytea NOT NULL,      -- sha256 of canonical inputs, for reuse
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, resolution_id),
  UNIQUE (user_id, inputs_hash)
);

CREATE TABLE usr.daily_target (
  user_id        uuid     NOT NULL,
  local_date     date     NOT NULL,
  nutrient_id    smallint NOT NULL CHECK (nutrient_id > 0),  -- [catalog ref.nutrient]
  target_low     numeric(14,6),
  target_high    numeric(14,6),
  upper_limit    numeric(14,6),
  resolution_id  uuid NOT NULL,
  computed_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, local_date, nutrient_id),
  FOREIGN KEY (user_id, resolution_id) REFERENCES usr.target_resolution
) PARTITION BY RANGE (local_date);
CREATE TABLE usr.daily_target_default PARTITION OF usr.daily_target DEFAULT;

-- Rollup: rebuilt from food_log_entry by a worker on change; disposable.
CREATE TABLE usr.daily_nutrient_total (
  user_id      uuid     NOT NULL,
  local_date   date     NOT NULL,
  nutrient_id  smallint NOT NULL CHECK (nutrient_id > 0),  -- [catalog ref.nutrient]
  amount       numeric(16,6) NOT NULL CHECK (amount >= 0),
  entry_count  int NOT NULL CHECK (entry_count >= 0),
  computed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, local_date, nutrient_id)
) PARTITION BY RANGE (local_date);
CREATE TABLE usr.daily_nutrient_total_default PARTITION OF usr.daily_nutrient_total DEFAULT;

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER touch BEFORE UPDATE ON usr.custom_food FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.custom_food
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('custom_food','custom_food_id');
CREATE TRIGGER sync  AFTER INSERT ON usr.custom_food_version
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('custom_food_version','custom_food_version_id');

CREATE TRIGGER touch BEFORE UPDATE ON usr.food_log_entry FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.food_log_entry
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('food_log_entry','entry_id','consumed_at');

CREATE TRIGGER sync  AFTER INSERT ON usr.custom_plan_version
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('custom_plan_version','custom_plan_version_id');

CREATE TRIGGER touch BEFORE UPDATE ON usr.plan_assignment FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.plan_assignment
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('plan_assignment','assignment_id');

CREATE TRIGGER touch BEFORE UPDATE ON usr.target_override FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.target_override
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('target_override','override_id');

COMMIT;
