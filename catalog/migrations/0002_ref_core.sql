-- =====================================================================
-- Atwater catalog · 0002 · reference catalog: units, authorities,
-- datasets, nutrients, life stages, nutrient reference values
--
-- The catalog lives in its own PostgreSQL cluster, separate from tenant
-- data. Published rows are never updated in place and ids are never
-- reused; new editions/releases are new rows. That is what lets the
-- tenant cluster reference catalog ids without foreign keys.
-- =====================================================================
BEGIN;

-- Units use UCUM codes so labs, labels and devices map cleanly.
CREATE TABLE ref.unit (
  unit_code     text PRIMARY KEY,               -- UCUM: g, mg, ug, kcal, kJ, mL, [cup_us], mg/dL, mmol/L ...
  dimension     text NOT NULL CHECK (dimension IN (
                  'mass','volume','energy','length','time','count','ratio','temperature','velocity',
                  'concentration','substance_concentration','pressure','rate','activity')),
  to_base       numeric(24,12),                 -- multiply to reach the dimension base (g, mL, kcal, m, s); NULL = non-linear/none
  display_name  text NOT NULL
);

CREATE TABLE ref.authority (
  authority_code text PRIMARY KEY,              -- NASEM_DRI, EFSA, WHO_FAO, UK_SACN, JP_MHLW, NHMRC, ICMR_NIN
  name           text NOT NULL,
  region         text NOT NULL,                 -- ISO 3166-1 alpha-2, 'EU' or 'INTL'
  url            text
);

CREATE TABLE ref.authority_edition (
  authority_code text NOT NULL REFERENCES ref.authority,
  edition        text NOT NULL,                 -- e.g. '2019-sodium-potassium', '2025'
  published_on   date,
  is_current     boolean NOT NULL DEFAULT false,
  PRIMARY KEY (authority_code, edition)
);
CREATE UNIQUE INDEX authority_edition_one_current
  ON ref.authority_edition (authority_code) WHERE is_current;

-- One row per imported release of a food-composition source.
CREATE TABLE ref.dataset (
  dataset_id     smallint PRIMARY KEY,          -- assigned explicitly, never reused
  code           text NOT NULL,                 -- FDC_FOUNDATION, FDC_SR_LEGACY, FDC_BRANDED, OFF, UK_COFID ...
  release_label  text NOT NULL,                 -- '2025-12', 'v8'
  name           text NOT NULL,
  license        text NOT NULL,                 -- SPDX-style: CC0-1.0, ODbL-1.0, OGL-UK-3.0 ...
  share_alike    boolean NOT NULL DEFAULT false,-- true => keep derived data isolated (ODbL)
  url            text,
  imported_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, release_label)
);

CREATE TABLE ref.nutrient (
  nutrient_id          smallint PRIMARY KEY,    -- stable, assigned in seed data, never reused
  code                 text NOT NULL UNIQUE,    -- internal slug: protein, vit_d, sodium ...
  name                 text NOT NULL,
  unit_code            text NOT NULL REFERENCES ref.unit,   -- canonical storage unit
  category             text NOT NULL CHECK (category IN (
                         'energy','macro','carb_fraction','fatty_acid','sterol',
                         'amino_acid','vitamin','mineral','water','other')),
  infoods_tag          text,                    -- FAO/INFOODS tagname (PROCNT, VITD ...)
  fdc_nutrient_number  text,                    -- USDA FoodData Central nutrient number
  parent_nutrient_id   smallint REFERENCES ref.nutrient,    -- added sugars -> total sugars
  sort_order           smallint NOT NULL DEFAULT 0,
  is_trackable         boolean  NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX nutrient_infoods_tag ON ref.nutrient (infoods_tag) WHERE infoods_tag IS NOT NULL;
CREATE UNIQUE INDEX nutrient_fdc_number  ON ref.nutrient (fdc_nutrient_number) WHERE fdc_nutrient_number IS NOT NULL;

-- Life-stage bands differ by authority, so each authority owns its groups.
CREATE TABLE ref.life_stage_group (
  life_stage_code      text PRIMARY KEY,        -- 'NASEM_DRI/M/31-50y'
  authority_code       text NOT NULL REFERENCES ref.authority,
  sex                  text NOT NULL CHECK (sex IN ('female','male','any')),
  age_min_months       int  NOT NULL CHECK (age_min_months >= 0),
  age_max_months       int,                     -- exclusive upper bound; NULL = open-ended
  physiological_state  text NOT NULL DEFAULT 'none'
                         CHECK (physiological_state IN ('none','pregnant','lactating')),
  label                text NOT NULL,
  CHECK (age_max_months IS NULL OR age_max_months > age_min_months)
);
CREATE INDEX life_stage_lookup
  ON ref.life_stage_group (authority_code, sex, physiological_state, age_min_months);

-- Every number a target can come from. value_type covers the vocabularies
-- of the major authorities (NASEM: EAR/RDA/AI/UL/AMDR/CDRR; EFSA: AR/PRI/AI/RI/UL;
-- UK: EAR/RNI/LRNI; Japan: EAR/RDA/AI/UL/DG).
CREATE TABLE ref.nutrient_reference_value (
  authority_code   text     NOT NULL,
  edition          text     NOT NULL,
  life_stage_code  text     NOT NULL REFERENCES ref.life_stage_group,
  nutrient_id      smallint NOT NULL REFERENCES ref.nutrient,
  value_type       text     NOT NULL CHECK (value_type IN (
                     'EAR','RDA','AI','UL','AMDR','CDRR','AR','PRI','RI','RNI','LRNI','DG')),
  basis            text     NOT NULL CHECK (basis IN (
                     'per_day','pct_energy','per_kg_body_weight','per_1000_kcal')),
  amount_low       numeric(14,6),
  amount_high      numeric(14,6),
  unit_code        text     NOT NULL REFERENCES ref.unit,
  applies_to       text     NOT NULL DEFAULT 'total_intake'
                     CHECK (applies_to IN ('total_intake','supplements_only','food_only')),
  note             text,
  source_url       text,
  PRIMARY KEY (authority_code, edition, life_stage_code, nutrient_id, value_type, basis),
  FOREIGN KEY (authority_code, edition) REFERENCES ref.authority_edition,
  CHECK (amount_low IS NOT NULL OR amount_high IS NOT NULL),
  CHECK (amount_low IS NULL OR amount_high IS NULL OR amount_low <= amount_high)
);

COMMIT;
