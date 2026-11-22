-- =====================================================================
-- Atwater catalog · 0008 · value-type roles and gestation stages
--
-- Design 0002:
--   A1  ref.value_type_role says what each authority's value types do in
--       target resolution, so the resolver isn't tied to NASEM's names.
--       Direction is in the data: a 'target' row with only amount_high is a
--       ceiling, with only amount_low a floor.
--   A2  life-stage groups can be specific to a trimester of pregnancy.
-- =====================================================================
BEGIN;

CREATE TABLE ref.value_type_role (
  authority_code  text NOT NULL REFERENCES ref.authority,
  value_type      text NOT NULL,
  role            text NOT NULL CHECK (role IN ('recommended','target','upper_limit','none')),
  note            text,
  PRIMARY KEY (authority_code, value_type)
);

ALTER TABLE ref.life_stage_group
  ADD COLUMN gestation_stage text
    CHECK (gestation_stage IN ('trimester_1','trimester_2','trimester_3')),
  ADD CONSTRAINT life_stage_gestation_only_when_pregnant
    CHECK (gestation_stage IS NULL OR physiological_state = 'pregnant');

-- 0005 granted on the tables that existed then; new tables need their own.
GRANT SELECT ON ref.value_type_role TO catalog_ro, catalog_admin;
GRANT INSERT ON ref.value_type_role TO catalog_admin;

COMMIT;
