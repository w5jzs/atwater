-- =====================================================================
-- Atwater catalog · 0003 · food catalog
--
-- ref.food is a stable identity ("cheddar cheese"); ref.food_version is an
-- immutable snapshot from one dataset release. Log entries point at a
-- food_version, so a source update never rewrites anyone's history.
-- =====================================================================
BEGIN;

CREATE TABLE ref.food_group (
  scheme       text NOT NULL,                  -- 'FOODEX2', 'WWEIA', 'ATWATER'
  group_code   text NOT NULL,
  parent_code  text,
  name         text NOT NULL,
  PRIMARY KEY (scheme, group_code),
  FOREIGN KEY (scheme, parent_code) REFERENCES ref.food_group (scheme, group_code)
);

-- Tags drive diet-plan rules (include/exclude) and allergen warnings.
CREATE TABLE ref.tag (
  tag_code  text PRIMARY KEY,                  -- 'dairy', 'legume', 'gluten', 'ultra_processed', 'allergen:peanut'
  kind      text NOT NULL CHECK (kind IN ('food_class','allergen','diet','processing','other')),
  name      text NOT NULL
);

CREATE TABLE ref.food (
  food_id         uuid PRIMARY KEY DEFAULT uuidv7(),
  canonical_name  text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ref.food_version (
  food_version_id      uuid PRIMARY KEY DEFAULT uuidv7(),
  food_id              uuid     NOT NULL REFERENCES ref.food,
  dataset_id           smallint NOT NULL REFERENCES ref.dataset,
  source_key           text     NOT NULL,      -- FDC fdc_id, OFF barcode/code, CoFID food code
  name                 text     NOT NULL,      -- name as published by the source
  brand                text,
  food_kind            text     NOT NULL CHECK (food_kind IN (
                         'foundation','generic','survey','branded','restaurant')),
  nutrient_basis       text     NOT NULL DEFAULT 'per_100g'
                         CHECK (nutrient_basis IN ('per_100g','per_100ml')),
  density_g_per_ml     numeric(8,4) CHECK (density_g_per_ml > 0),   -- enables mL <-> g
  -- How the source derived energy (see Atwater factors). Never recompute
  -- 4/4/9 blindly; store what the source reports and how.
  energy_method        text     NOT NULL CHECK (energy_method IN (
                         'label','atwater_general','atwater_specific',
                         'eu_regulation','measured','other')),
  protein_kcal_per_g   numeric(5,3),           -- specific Atwater factors when published
  fat_kcal_per_g       numeric(5,3),
  carb_kcal_per_g      numeric(5,3),
  group_scheme         text,
  group_code           text,
  is_current           boolean  NOT NULL DEFAULT true,
  superseded_by        uuid REFERENCES ref.food_version,
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dataset_id, source_key),
  FOREIGN KEY (group_scheme, group_code) REFERENCES ref.food_group (scheme, group_code),
  CHECK ((group_scheme IS NULL) = (group_code IS NULL)),
  CHECK (superseded_by IS NULL OR NOT is_current)
);
CREATE INDEX food_version_food     ON ref.food_version (food_id);
CREATE INDEX food_version_current  ON ref.food_version (food_id) WHERE is_current;

-- Nutrient vector: amount per 100 g (or 100 mL) in the nutrient's canonical unit.
CREATE TABLE ref.food_nutrient (
  food_version_id  uuid     NOT NULL REFERENCES ref.food_version ON DELETE CASCADE,
  nutrient_id      smallint NOT NULL REFERENCES ref.nutrient,
  amount           numeric(14,6) NOT NULL CHECK (amount >= 0),
  derivation       text CHECK (derivation IN (
                     'analytical','calculated','imputed','label','assumed_zero')),
  PRIMARY KEY (food_version_id, nutrient_id)
);
CREATE INDEX food_nutrient_by_nutrient ON ref.food_nutrient (nutrient_id, amount);

-- Localized names for multilingual search and display.
CREATE TABLE ref.food_name (
  food_version_id  uuid NOT NULL REFERENCES ref.food_version ON DELETE CASCADE,
  locale           text NOT NULL,              -- BCP 47: en-US, es-MX, ja-JP
  name             text NOT NULL,
  is_primary       boolean NOT NULL DEFAULT false,
  PRIMARY KEY (food_version_id, locale, name)
);
CREATE UNIQUE INDEX food_name_one_primary ON ref.food_name (food_version_id, locale) WHERE is_primary;
CREATE INDEX food_name_trgm ON ref.food_name USING gin (name gin_trgm_ops);

-- Household measures. Every portion resolves to grams.
CREATE TABLE ref.food_portion (
  portion_id       uuid PRIMARY KEY DEFAULT uuidv7(),
  food_version_id  uuid NOT NULL REFERENCES ref.food_version ON DELETE CASCADE,
  label            text NOT NULL,              -- '1 cup, chopped', '1 large', '1 slice'
  amount           numeric(10,3) NOT NULL DEFAULT 1 CHECK (amount > 0),
  unit_code        text REFERENCES ref.unit,   -- set when UCUM can express it ([cup_us]); else NULL
  gram_weight      numeric(10,3) NOT NULL CHECK (gram_weight > 0),
  is_default       boolean  NOT NULL DEFAULT false,
  sort_order       smallint NOT NULL DEFAULT 0
);
CREATE INDEX food_portion_food ON ref.food_portion (food_version_id, sort_order);
CREATE UNIQUE INDEX food_portion_one_default ON ref.food_portion (food_version_id) WHERE is_default;

CREATE TABLE ref.food_barcode (
  gtin             text NOT NULL CHECK (gtin ~ '^[0-9]{8,14}$'),   -- UPC/EAN normalized to digits
  food_version_id  uuid NOT NULL REFERENCES ref.food_version ON DELETE CASCADE,
  PRIMARY KEY (gtin, food_version_id)
);
CREATE INDEX food_barcode_version ON ref.food_barcode (food_version_id);

CREATE TABLE ref.food_tag (
  food_version_id  uuid NOT NULL REFERENCES ref.food_version ON DELETE CASCADE,
  tag_code         text NOT NULL REFERENCES ref.tag,
  PRIMARY KEY (food_version_id, tag_code)
);
CREATE INDEX food_tag_by_tag ON ref.food_tag (tag_code);

COMMIT;
