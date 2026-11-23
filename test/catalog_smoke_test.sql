-- Atwater catalog smoke test (scratch DB, superuser, after migrations + seed).
-- Runs in one transaction and ROLLS BACK: safe on a shared staging database.
\set ON_ERROR_STOP 1
\pset tuples_only on
BEGIN;
\ir _helpers.sql

SELECT t.check('running on PostgreSQL 18+', current_setting('server_version_num')::int >= 180000);
SELECT t.check('seed loaded the core nutrients', (SELECT count(*) FROM ref.nutrient WHERE nutrient_id IN (1,2,3,4,201,202,305)) = 7);
SELECT t.check('seed loaded NASEM values', (SELECT count(*) FROM ref.nutrient_reference_value) > 0);

SET ROLE catalog_admin;
INSERT INTO ref.dataset (dataset_id, code, release_label, name, license)
  VALUES (32000, 'ATWATER_SMOKE', 'smoke', 'Smoke test dataset', 'CC0-1.0');
INSERT INTO ref.food (food_id, canonical_name) VALUES ('01900000-0000-7000-8000-00000000f001', 'Smoke egg');
INSERT INTO ref.food_version (food_id, dataset_id, source_key, name, food_kind, energy_method)
  VALUES ('01900000-0000-7000-8000-00000000f001', 32000, 'smoke-egg', 'Smoke egg, raw', 'foundation', 'atwater_specific');
SELECT t.check('native uuidv7() defaults produce version-7 ids',
  (SELECT uuid_extract_version(food_version_id) FROM ref.food_version WHERE source_key = 'smoke-egg') = 7);
INSERT INTO ref.food_nutrient (food_version_id, nutrient_id, amount)
  SELECT food_version_id, 1, 143 FROM ref.food_version WHERE source_key = 'smoke-egg';

SELECT t.expect_error('published food versions cannot be edited',
  $$UPDATE ref.food_version SET name = 'renamed' WHERE source_key = 'smoke-egg'$$, '42501');
UPDATE ref.food_version SET is_current = false WHERE source_key = 'smoke-egg';
SELECT t.check('lifecycle flag can be flipped',
  (SELECT NOT is_current FROM ref.food_version WHERE source_key = 'smoke-egg'));
SELECT t.expect_error('catalog is append-only (no DELETE)',
  $$DELETE FROM ref.food_nutrient WHERE amount = 143 AND nutrient_id = 1$$, '42501');
SELECT t.expect_error('superseded version must not be current',
  $$UPDATE ref.food_version SET is_current = true, superseded_by = food_version_id WHERE source_key = 'smoke-egg'$$, '23514');
RESET ROLE;

SET ROLE catalog_ro;
SELECT t.expect_error('readers cannot write',
  $$INSERT INTO ref.tag (tag_code, kind, name) VALUES ('x','other','x')$$, '42501');
SELECT t.check('readers can read', (SELECT count(*) FROM ref.unit) > 0);
RESET ROLE;

SELECT t.expect_error('reference values need a known edition',
  $$INSERT INTO ref.nutrient_reference_value (authority_code, edition, life_stage_code, nutrient_id, value_type, basis, amount_low, unit_code)
    VALUES ('NASEM_DRI', 'no-such-edition', 'NASEM_DRI/M/31-50y', 201, 'RDA', 'per_day', 90, 'mg')$$, '23503');

SELECT t.check('ble_uuid16 expands SIG short UUIDs',
  ref.ble_uuid16('2A37') = '00002a37-0000-1000-8000-00805f9b34fb'::uuid);
SELECT t.check('blood pressure characteristic feeds systolic, diastolic and pulse',
  (SELECT count(*) FROM ref.ble_gatt_map WHERE characteristic_uuid = ref.ble_uuid16('2A35')) = 3);
SELECT t.check('blood-pressure schema feeds two metrics',
  (SELECT count(*) FROM ref.omh_schema_map WHERE schema_name = 'blood-pressure') = 2);
SELECT t.expect_error('mappings must target a known metric',
  $$INSERT INTO ref.omh_schema_map (namespace, schema_name, metric_code, value_path) VALUES ('omh','x','nope','$.x')$$, '23503');
SELECT t.expect_error('only omh/ieee schema namespaces',
  $$INSERT INTO ref.omh_schema_map (namespace, schema_name, metric_code, value_path) VALUES ('acme','x','steps','$.x')$$, '23514');

-- energy equations (0007): append-only data, one row per edition, group and activity level.
-- Coefficients below are dummies for the test, not real NASEM values.
SET ROLE catalog_admin;
INSERT INTO ref.authority_edition (authority_code, edition) VALUES ('NASEM_DRI', 'smoke-energy');
INSERT INTO ref.energy_equation (authority_code, edition, life_stage_code, activity_level,
                                 intercept_kcal, age_years_coef, height_cm_coef, weight_kg_coef)
  VALUES ('NASEM_DRI', 'smoke-energy', 'NASEM_DRI/M/31-50y', 'low_active', 1000, -10, 5, 15);
SELECT t.expect_error('energy equations are append-only',
  $$UPDATE ref.energy_equation SET intercept_kcal = 1 WHERE edition = 'smoke-energy'$$, '42501');
SELECT t.expect_error('energy equations need a known activity level',
  $$INSERT INTO ref.energy_equation (authority_code, edition, life_stage_code, activity_level, intercept_kcal)
    VALUES ('NASEM_DRI', 'smoke-energy', 'NASEM_DRI/F/31-50y', 'couch', 1)$$, '23514');
RESET ROLE;
SET ROLE catalog_ro;
SELECT t.check('readers can read energy equations',
  (SELECT count(*) FROM ref.energy_equation WHERE edition = 'smoke-energy') = 1);
RESET ROLE;

-- NASEM 2023 adult EER seed (0003): all 8 equations, and the sign convention
-- (negative age coefficient) gives the right number. Hand-computed from
-- Table S-3, men, inactive, age 40, 180 cm, 105 kg:
--   753.07 - 10.83*40 + 6.50*180 + 14.10*105 = 2970.37 kcal/d
SELECT t.check('seed loaded 8 NASEM 2023 adult EER equations',
  (SELECT count(*) FROM ref.energy_equation WHERE authority_code = 'NASEM_DRI' AND edition = '2023-energy') = 8);
SELECT t.check('EER formula and signs reproduce a hand-computed value',
  (SELECT intercept_kcal + age_years_coef * 40 + height_cm_coef * 180 + weight_kg_coef * 105 + extra_kcal
     FROM ref.energy_equation
    WHERE edition = '2023-energy' AND life_stage_code = 'NASEM_DRI/M/19+y' AND activity_level = 'inactive') = 2970.37);

-- NASEM DRIs (0004, generated from catalog/data/nasem-dri): every life-stage
-- group has targets, adults have AMDRs, and spot values match the tables.
SELECT t.check('NASEM DRIs cover all 22 life-stage groups',
  (SELECT count(DISTINCT life_stage_code) FROM ref.nutrient_reference_value
    WHERE authority_code = 'NASEM_DRI' AND edition = 'consolidated-2019') = 22);
SELECT t.check('every group 1 y and older has fat, carbohydrate and protein AMDRs',
  NOT EXISTS (SELECT 1 FROM ref.life_stage_group g
               WHERE g.authority_code = 'NASEM_DRI' AND g.age_min_months >= 12 AND g.life_stage_code NOT LIKE '%/19+y'
                 AND (SELECT count(*) FROM ref.nutrient_reference_value r
                       WHERE r.life_stage_code = g.life_stage_code AND r.value_type = 'AMDR') <> 3));
SELECT t.check('DRI spot values: pregnancy 31-50 zinc RDA 11 mg, men 19-30 copper UL 10 mg',
  (SELECT amount_low FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
    WHERE r.life_stage_code = 'NASEM_DRI/P/31-50y' AND n.code = 'zinc' AND r.value_type = 'RDA') = 11
  AND (SELECT amount_high FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
    WHERE r.life_stage_code = 'NASEM_DRI/M/19-30y' AND n.code = 'copper' AND r.value_type = 'UL') = 10);

-- value-type roles and gestation stages (0008, seed 0005)
SELECT t.check('every NASEM value type in use has a role',
  NOT EXISTS (SELECT DISTINCT value_type FROM ref.nutrient_reference_value r
               WHERE r.authority_code = 'NASEM_DRI'
                 AND NOT EXISTS (SELECT 1 FROM ref.value_type_role vr
                                  WHERE vr.authority_code = r.authority_code AND vr.value_type = r.value_type)));
SELECT t.expect_error('unknown roles rejected',
  $$INSERT INTO ref.value_type_role (authority_code, value_type, role) VALUES ('EFSA', 'XX', 'floor')$$, '23514');
SELECT t.expect_error('gestation stage only on pregnant groups',
  $$INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, label, gestation_stage)
    VALUES ('SMOKE/x', 'EFSA', 'female', 216, 'x', 'trimester_2')$$, '23514');
INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, physiological_state, label, gestation_stage)
  VALUES ('SMOKE/P/T2', 'EFSA', 'female', 216, 'pregnant', 'Smoke pregnancy T2', 'trimester_2');
SELECT t.check('trimester groups can be stored',
  (SELECT gestation_stage FROM ref.life_stage_group WHERE life_stage_code = 'SMOKE/P/T2') = 'trimester_2');

-- US Dietary Guidelines 2025-2030 (seed 0006): a guideline with roles, no ULs
SELECT t.check('DGA: saturated fat <= 10% of energy for adults, no alcohol in pregnancy',
  (SELECT amount_high FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
    WHERE r.authority_code = 'US_DGA' AND r.life_stage_code = 'US_DGA/A/19+y' AND n.code = 'sat_fat') = 10
  AND (SELECT count(*) FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
        WHERE r.authority_code = 'US_DGA' AND n.code = 'alcohol' AND r.amount_high = 0) = 2);
SELECT t.check('DGA sets no upper limits and every value type it uses has a role',
  NOT EXISTS (SELECT 1 FROM ref.nutrient_reference_value WHERE authority_code = 'US_DGA' AND value_type = 'UL')
  AND NOT EXISTS (SELECT 1 FROM ref.nutrient_reference_value r WHERE r.authority_code = 'US_DGA'
                   AND NOT EXISTS (SELECT 1 FROM ref.value_type_role vr
                                    WHERE vr.authority_code = 'US_DGA' AND vr.value_type = r.value_type)));

-- DGA decisions (seed 0007): sat fat from age 2, adult protein, no added sugars at any age
SELECT t.check('DGA covers every age for added sugars, sat fat from 2, protein for adults',
  (SELECT count(*) FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
    WHERE r.authority_code = 'US_DGA' AND n.code = 'added_sugars' AND r.amount_high = 0) = 7
  AND (SELECT count(*) FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
        WHERE r.authority_code = 'US_DGA' AND n.code = 'sat_fat') = 6
  AND (SELECT amount_low || '-' || amount_high FROM ref.nutrient_reference_value r JOIN ref.nutrient n USING (nutrient_id)
        WHERE r.life_stage_code = 'US_DGA/A/19+y' AND n.code = 'protein') = '1.200000-1.600000'
  AND NOT EXISTS (SELECT 1 FROM ref.nutrient_reference_value r JOIN ref.life_stage_group g USING (life_stage_code)
                   JOIN ref.nutrient n USING (nutrient_id)
                   WHERE r.authority_code = 'US_DGA' AND n.code = 'sat_fat' AND g.age_min_months < 24 AND g.physiological_state = 'none'));

-- barcodes are GTIN-14 with a valid check digit (0009)
SELECT t.check('GTIN-14 check digits',
  ref.gtin14_ok('00036000291452') AND NOT ref.gtin14_ok('00036000291453')
  AND NOT ref.gtin14_ok('036000291452') AND NOT ref.gtin14_ok('00000000000000'));
SET ROLE catalog_admin;
INSERT INTO ref.food_barcode (gtin, food_version_id)
  SELECT '00036000291452', food_version_id FROM ref.food_version WHERE source_key = 'smoke-egg';
SELECT t.check('a padded UPC-A is stored',
  (SELECT count(*) FROM ref.food_barcode WHERE gtin = lpad('036000291452', 14, '0')) = 1);
SELECT t.expect_error('unpadded barcodes rejected',
  $$INSERT INTO ref.food_barcode (gtin, food_version_id)
    SELECT '036000291452', food_version_id FROM ref.food_version WHERE source_key = 'smoke-egg'$$, '23514');
SELECT t.expect_error('bad check digit rejected',
  $$INSERT INTO ref.food_barcode (gtin, food_version_id)
    SELECT '00036000291453', food_version_id FROM ref.food_version WHERE source_key = 'smoke-egg'$$, '23514');
RESET ROLE;

-- grants lint: 0005 granted on the tables that existed then, so every later
-- table needs its own grants. Catch a table someone forgot.
SELECT t.check('every ref table is readable by catalog_ro and catalog_admin',
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'ref' AND c.relkind IN ('r','p')
                 AND NOT (has_table_privilege('catalog_ro', c.oid, 'SELECT')
                          AND has_table_privilege('catalog_admin', c.oid, 'SELECT'))));
SELECT t.check('catalog_admin can insert into every ref table',
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'ref' AND c.relkind IN ('r','p')
                 AND NOT has_table_privilege('catalog_admin', c.oid, 'INSERT')));
SELECT t.check('no catalog role can delete from any ref table',
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'ref' AND c.relkind IN ('r','p')
                 AND (has_table_privilege('catalog_ro', c.oid, 'DELETE')
                      OR has_table_privilege('catalog_admin', c.oid, 'DELETE'))));

ROLLBACK;
\echo 'CATALOG SMOKE TESTS PASSED (rolled back)'
