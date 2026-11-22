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
