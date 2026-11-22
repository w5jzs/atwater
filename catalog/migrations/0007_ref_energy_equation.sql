-- =====================================================================
-- Atwater catalog · 0007 · energy-requirement equations
--
-- Design 0001 (D4): the energy target for method "eer" comes from an
-- authority's Estimated Energy Requirement equations. Their coefficients
-- are catalog data, append-only like everything else here; the resolver
-- implements only the formula's shape:
--
--   EER (kcal/day) = intercept_kcal
--                  + age_years_coef  * age in whole years
--                  + height_cm_coef  * height in cm
--                  + weight_kg_coef  * body mass in kg
--                  + extra_kcal      (constant additions, e.g. energy
--                                     deposition in growth or lactation)
--
-- One row per authority edition, life-stage group and physical-activity
-- category (usr.account.activity_level). Pregnancy equations that depend
-- on gestational age need another coefficient; add it in a later
-- migration when they're loaded.
--
-- No rows yet: coefficients must be loaded from the source report (NASEM
-- 2023 for NASEM_DRI), with source_url set, not typed from memory.
-- =====================================================================
BEGIN;

CREATE TABLE ref.energy_equation (
  authority_code   text NOT NULL,
  edition          text NOT NULL,
  life_stage_code  text NOT NULL REFERENCES ref.life_stage_group,
  activity_level   text NOT NULL CHECK (activity_level IN ('inactive','low_active','active','very_active')),
  intercept_kcal   numeric(10,4) NOT NULL,
  age_years_coef   numeric(10,4) NOT NULL DEFAULT 0,
  height_cm_coef   numeric(10,4) NOT NULL DEFAULT 0,
  weight_kg_coef   numeric(10,4) NOT NULL DEFAULT 0,
  extra_kcal       numeric(10,4) NOT NULL DEFAULT 0,
  source_url       text,
  note             text,
  PRIMARY KEY (authority_code, edition, life_stage_code, activity_level),
  FOREIGN KEY (authority_code, edition) REFERENCES ref.authority_edition
);

-- 0005 granted on the tables that existed then; new tables need their own.
GRANT SELECT ON ref.energy_equation TO catalog_ro, catalog_admin;
GRANT INSERT ON ref.energy_equation TO catalog_admin;

COMMIT;
