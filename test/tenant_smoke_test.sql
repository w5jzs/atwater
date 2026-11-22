-- Atwater tenant smoke test (scratch DB, superuser, after migrations).
-- The tenant cluster has no catalog tables: catalog ids below are just
-- well-formed uuids/codes, exactly as middleware would pass them through.
-- Runs in one transaction and ROLLS BACK: safe on a shared staging database.
-- Needs SET membership in app_rw and purger (bootstrap grants it).
\set ON_ERROR_STOP 1
\pset tuples_only on
BEGIN;
\ir _helpers.sql

SELECT t.check('running on PostgreSQL 18+', current_setting('server_version_num')::int >= 180000);

-- ---------- test day ----------
-- Every fixture lands on the 3rd of the current UTC month. That month is
-- always inside the window tenant/ops/partitions.sql keeps (the narrowest,
-- change_log, reaches one month back), and the 3rd keeps local offsets like
-- -05 from crossing a month boundary. Hard-coded dates drift into DEFAULT.
CREATE FUNCTION t.day() RETURNS date LANGUAGE sql STABLE
  AS $$ SELECT date_trunc('month', now() AT TIME ZONE 'UTC')::date + 2 $$;
CREATE FUNCTION t.at(local_time text) RETURNS timestamptz LANGUAGE sql STABLE
  AS $$ SELECT (t.day()::text || ' ' || local_time)::timestamptz $$;
-- Total rows in every usr DEFAULT partition; should stay 0.
CREATE FUNCTION t.default_partition_rows() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r record; n bigint; total bigint := 0;
BEGIN
  FOR r IN SELECT c.oid::regclass AS part
             FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
            WHERE ns.nspname = 'usr' AND c.relispartition
              AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT' LOOP
    EXECUTE format('SELECT count(*) FROM %s', r.part) INTO n;
    total := total + n;
  END LOOP;
  RETURN total;
END $$;

-- ---------- fixtures (superuser) ----------
-- This month's food_log partition, so the routing check below doesn't depend
-- on partitions.sql having run (bootstrap runs it; a bare staging DB may not).
DO $$
DECLARE
  m date := date_trunc('month', t.day())::date;
  p text := 'food_log_entry_p' || to_char(t.day(), 'YYYYMM');
BEGIN
  IF to_regclass(format('usr.%I', p)) IS NULL THEN
    EXECUTE format('CREATE TABLE usr.%I PARTITION OF usr.food_log_entry FOR VALUES FROM (%L) TO (%L)',
                   p, m::timestamp AT TIME ZONE 'UTC', (m + interval '1 month')::timestamp AT TIME ZONE 'UTC');
  END IF;
END $$;


-- ---------- provisioning: only the provisioner creates users ----------
SET ROLE provisioner;
INSERT INTO usr.account (user_id, kek_id, wrapped_dek, reference_sex, birth_date, tz) VALUES
  ('01900000-0000-7000-8000-00000000000a', 'kek-test', '\x00', 'male',   '1977-01-01', 'America/Chicago'),
  ('01900000-0000-7000-8000-00000000000b', 'kek-test', '\x00', 'female', '1985-06-01', 'America/Chicago');
INSERT INTO usr.data_source (user_id, source_id, kind) VALUES
  ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000d1', 'manual'),
  ('01900000-0000-7000-8000-00000000000b', '01900000-0000-7000-8000-0000000000d2', 'manual');
RESET ROLE;

-- a row for user B, written as superuser, that A must never see
INSERT INTO usr.food_log_entry (user_id, consumed_at, entry_id, local_date, tz, food_version_id, quantity, grams, source_id)
VALUES ('01900000-0000-7000-8000-00000000000b', t.at('08:00-05'), uuidv7(), t.day(), 'America/Chicago',
        '01900000-0000-7000-8000-0000000000a1', 2, 100, '01900000-0000-7000-8000-0000000000d2');

-- ---------- the app, acting as user A ----------
SET ROLE app_rw;
SET app.user_id = '01900000-0000-7000-8000-00000000000a';

SELECT t.expect_error('app cannot create users',
  $$INSERT INTO usr.account (user_id, kek_id, wrapped_dek) VALUES (uuidv7(), 'k', '\x00')$$, '42501');

SELECT t.expect_error('app cannot touch encryption keys',
  $$UPDATE usr.account SET wrapped_dek = '\x01'$$, '42501');

INSERT INTO usr.food_log_entry (user_id, consumed_at, entry_id, local_date, tz, meal_slot, food_version_id,
                                quantity, portion_id, grams, source_id, external_id)
VALUES ('01900000-0000-7000-8000-00000000000a', t.at('07:30-05'), '01900000-0000-7000-8000-0000000000e1',
        t.day(), 'America/Chicago', 'breakfast', '01900000-0000-7000-8000-0000000000a1',
        3, '01900000-0000-7000-8000-0000000000b1', 150, '01900000-0000-7000-8000-0000000000d1', 'import-123');

SELECT t.check('RLS hides other users rows',
  (SELECT count(*) FROM usr.food_log_entry) = 1);

SELECT t.expect_error('RLS blocks writing as another user',
  $$INSERT INTO usr.food_log_entry (user_id, consumed_at, entry_id, local_date, tz, food_version_id, quantity, grams, source_id)
    VALUES ('01900000-0000-7000-8000-00000000000b', t.at('09:00-05'), uuidv7(), t.day(), 'UTC',
            '01900000-0000-7000-8000-0000000000a1', 1, 50, '01900000-0000-7000-8000-0000000000d2')$$, '42501');

SELECT t.expect_error('import dedupe on (source, external_id)',
  $$INSERT INTO usr.food_log_entry (user_id, consumed_at, entry_id, local_date, tz, food_version_id, quantity, grams, source_id, external_id)
    VALUES ('01900000-0000-7000-8000-00000000000a', t.at('07:30-05'), uuidv7(), t.day(), 'UTC',
            '01900000-0000-7000-8000-0000000000a1', 1, 50, '01900000-0000-7000-8000-0000000000d1', 'import-123')$$, '23505');

UPDATE usr.food_log_entry SET quantity = 4, grams = 200
 WHERE user_id = '01900000-0000-7000-8000-00000000000a' AND entry_id = '01900000-0000-7000-8000-0000000000e1';

SELECT t.check('optimistic version bumped on update',
  (SELECT version FROM usr.food_log_entry WHERE entry_id = '01900000-0000-7000-8000-0000000000e1') = 2);

SELECT t.expect_error('user_id is immutable',
  $$UPDATE usr.food_log_entry SET user_id = '01900000-0000-7000-8000-00000000000b'
     WHERE entry_id = '01900000-0000-7000-8000-0000000000e1'$$, '23514');

SELECT t.expect_error('app cannot hard-delete',
  $$DELETE FROM usr.food_log_entry WHERE entry_id = '01900000-0000-7000-8000-0000000000e1'$$, '42501');

UPDATE usr.food_log_entry SET deleted_at = now()
 WHERE user_id = '01900000-0000-7000-8000-00000000000a' AND entry_id = '01900000-0000-7000-8000-0000000000e1';

-- profile edit bumps version but not the sync cursor
UPDATE usr.account SET tz = 'America/Denver';

-- custom foods: header + first version (deferred FK, checked below); versions are insert-only
INSERT INTO usr.custom_food (user_id, custom_food_id, kind, name, current_version_id)
VALUES ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000c1', 'recipe', 'Venison chili',
        '01900000-0000-7000-8000-0000000000c2');
INSERT INTO usr.custom_food_version (user_id, custom_food_version_id, custom_food_id, version, yield_grams, servings)
VALUES ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000c2',
        '01900000-0000-7000-8000-0000000000c1', 1, 2400, 8);
SET CONSTRAINTS ALL IMMEDIATE;   -- what COMMIT would check
SET CONSTRAINTS ALL DEFERRED;
SELECT t.expect_error('custom food versions are immutable',
  $$UPDATE usr.custom_food_version SET servings = 10$$, '42501');

-- recipes can't point at another user's data (composite FKs)
RESET ROLE;
INSERT INTO usr.custom_food (user_id, custom_food_id, kind, name)
  VALUES ('01900000-0000-7000-8000-00000000000b', '01900000-0000-7000-8000-0000000000f1', 'food', 'B secret food');
INSERT INTO usr.custom_food_version (user_id, custom_food_version_id, custom_food_id, version)
  VALUES ('01900000-0000-7000-8000-00000000000b', '01900000-0000-7000-8000-0000000000f2',
          '01900000-0000-7000-8000-0000000000f1', 1);

SET ROLE app_rw;
SET app.user_id = '01900000-0000-7000-8000-00000000000a';

SELECT t.expect_error('cannot log another user''s custom food',
  $$INSERT INTO usr.food_log_entry (user_id, consumed_at, entry_id, local_date, tz, custom_food_version_id, quantity, grams, source_id)
    VALUES ('01900000-0000-7000-8000-00000000000a', t.at('12:00-05'), uuidv7(), t.day(), 'UTC',
            '01900000-0000-7000-8000-0000000000f2', 1, 100, '01900000-0000-7000-8000-0000000000d1')$$, '23503');

-- one active plan at a time
INSERT INTO usr.plan_assignment (user_id, assignment_id, plan_version_id, energy_adjust_kcal, valid)
  VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), '01900000-0000-7000-8000-0000000000f8', -500,
          daterange(date_trunc('month', t.day())::date, NULL));
SELECT t.expect_error('overlapping plan assignments rejected',
  $$INSERT INTO usr.plan_assignment (user_id, assignment_id, plan_version_id, valid)
    VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), '01900000-0000-7000-8000-0000000000f9',
            daterange((date_trunc('month', t.day()) + interval '2 months')::date,
                      (date_trunc('month', t.day()) + interval '3 months')::date))$$, '23P01');

-- activity session sanity check
SELECT t.expect_error('activity must end after it starts',
  $$INSERT INTO usr.activity_session (user_id, started_at, session_id, ended_at, local_date, tz, activity_code, source_id)
    VALUES ('01900000-0000-7000-8000-00000000000a', t.at('17:00-05'), uuidv7(), t.at('16:00-05'),
            t.day(), 'UTC', 'TEST-1', '01900000-0000-7000-8000-0000000000d1')$$, '23514');

-- sync feed: data_source insert, entry insert, update, soft delete, custom_food,
-- custom_food_version, plan_assignment = 7 changes; profile edit is not one.
SELECT t.check('sync cursor counts every synced change',
  (SELECT sync_seq FROM usr.account) = 7);
SELECT t.check('soft delete published as delete op',
  (SELECT op FROM usr.change_log WHERE entity = 'food_log_entry' ORDER BY seq DESC LIMIT 1) = 'delete');
SELECT t.check('change log carries the partition key',
  (SELECT bool_and(entity_ts IS NOT NULL) FROM usr.change_log WHERE entity = 'food_log_entry'));
SELECT t.check('profile edit bumped account version',
  (SELECT version FROM usr.account) = 2);
-- activity level: a profile field the app can set (column-level grant, 0008)
UPDATE usr.account SET activity_level = 'low_active';
SELECT t.check('app can set activity level',
  (SELECT activity_level FROM usr.account) = 'low_active');
SELECT t.expect_error('unknown activity levels rejected',
  $$UPDATE usr.account SET activity_level = 'couch'$$, '23514');
-- opt-in guidelines (0010): the app can set them; malformed codes are rejected
UPDATE usr.account SET guideline_codes = '{US_DGA}';
SELECT t.check('app can set guideline codes', (SELECT guideline_codes FROM usr.account) = '{US_DGA}');
SELECT t.expect_error('malformed guideline codes rejected',
  $$UPDATE usr.account SET guideline_codes = '{"drop table; --"}'$$, '23514');
SELECT t.expect_error('NULL guideline codes rejected',
  $$UPDATE usr.account SET guideline_codes = '{US_DGA,NULL}'$$, '23514');
-- pregnancy due date (0010): pregnant periods only
INSERT INTO usr.physiological_period (user_id, period_id, state, valid, due_date)
  VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), 'pregnant', daterange(t.day(), t.day() + 200), t.day() + 180);
SELECT t.check('pregnant periods take a due date',
  (SELECT due_date FROM usr.physiological_period WHERE state = 'pregnant') = t.day() + 180);
SELECT t.expect_error('due date only on pregnant periods',
  $$INSERT INTO usr.physiological_period (user_id, period_id, state, valid, due_date)
    VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), 'lactating', daterange(t.day() + 300, t.day() + 400), t.day() + 300)$$, '23514');
-- target resolutions carry warnings (0009); default is an empty array
INSERT INTO usr.target_resolution (user_id, resolution_id, inputs, inputs_hash)
  VALUES ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000e2', '{}', sha256('r1'));
INSERT INTO usr.target_resolution (user_id, resolution_id, inputs, inputs_hash, warnings)
  VALUES ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000e3', '{}', sha256('r2'),
          '[{"code": "exceeds_upper_limit", "nutrient": "vit_d"}]');
SELECT t.check('resolution warnings default to an empty array',
  (SELECT warnings FROM usr.target_resolution WHERE resolution_id = '01900000-0000-7000-8000-0000000000e2') = '[]');
SELECT t.check('resolution warnings stored',
  (SELECT warnings->0->>'code' FROM usr.target_resolution WHERE resolution_id = '01900000-0000-7000-8000-0000000000e3')
    = 'exceeds_upper_limit');
SELECT t.expect_error('resolution warnings must be an array',
  $$INSERT INTO usr.target_resolution (user_id, resolution_id, inputs, inputs_hash, warnings)
    VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), '{}', sha256('r3'), '{"code": "x"}')$$, '23514');
-- open-standard ingest: a Gadgetbridge source, one batch, idempotent re-upload
INSERT INTO usr.data_source (user_id, source_id, kind, label)
  VALUES ('01900000-0000-7000-8000-00000000000a', '01900000-0000-7000-8000-0000000000d3', 'gadgetbridge', 'Bangle.js 2');
INSERT INTO usr.ingest_batch (user_id, batch_id, source_id, format, payload_sha256, payload_bytes)
  VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), '01900000-0000-7000-8000-0000000000d3',
          'gadgetbridge_export', sha256('export-1'), 8);
SELECT t.expect_error('same payload from same source is ingested once',
  $$INSERT INTO usr.ingest_batch (user_id, batch_id, source_id, format, payload_sha256, payload_bytes)
    VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), '01900000-0000-7000-8000-0000000000d3',
            'gadgetbridge_export', sha256('export-1'), 8)$$, '23505');
SELECT t.expect_error('unknown source kinds rejected',
  $$INSERT INTO usr.data_source (user_id, source_id, kind) VALUES ('01900000-0000-7000-8000-00000000000a', uuidv7(), 'acme_cloud')$$, '23514');

SELECT t.expect_error('app cannot forge change log rows',
  $$INSERT INTO usr.change_log (user_id, seq, entity, entity_id, op)
    VALUES ('01900000-0000-7000-8000-00000000000a', 999, 'x', uuidv7(), 'upsert')$$, '42501');
RESET ROLE;

SELECT t.check('entries routed to this month''s partition, not DEFAULT',
  (SELECT bool_and(tableoid = format('usr.food_log_entry_p%s', to_char(t.day(), 'YYYYMM'))::regclass) FROM usr.food_log_entry
    WHERE user_id IN ('01900000-0000-7000-8000-00000000000a','01900000-0000-7000-8000-00000000000b')));

-- user B has device data from an ingested batch; purge must still cascade
INSERT INTO usr.data_source (user_id, source_id, kind)
  VALUES ('01900000-0000-7000-8000-00000000000b', '01900000-0000-7000-8000-0000000000d4', 'ble_gatt');
INSERT INTO usr.ingest_batch (user_id, batch_id, source_id, format, payload_sha256, payload_bytes)
  VALUES ('01900000-0000-7000-8000-00000000000b', '01900000-0000-7000-8000-0000000000b9',
          '01900000-0000-7000-8000-0000000000d4', 'ble_session', sha256('ble-1'), 5);
INSERT INTO usr.observation_sample (user_id, observed_at, metric_code, source_id, value, ingest_batch_id)
  VALUES ('01900000-0000-7000-8000-00000000000b', now(), 'heart_rate', '01900000-0000-7000-8000-0000000000d4', 62,
          '01900000-0000-7000-8000-0000000000b9');

-- Every fixture row so far (food log, change log, samples, ...) must sit in a
-- real partition. Catches dates drifting out of the partition window.
SELECT t.check('no test rows in any DEFAULT partition', t.default_partition_rows() = 0);

SET ROLE purger;
DELETE FROM usr.account WHERE user_id = '01900000-0000-7000-8000-00000000000b';
RESET ROLE;
SELECT t.check('purge cascades through user B''s data',
  NOT EXISTS (SELECT 1 FROM usr.food_log_entry WHERE user_id = '01900000-0000-7000-8000-00000000000b')
  AND NOT EXISTS (SELECT 1 FROM usr.custom_food WHERE user_id = '01900000-0000-7000-8000-00000000000b')
  AND NOT EXISTS (SELECT 1 FROM usr.observation_sample WHERE user_id = '01900000-0000-7000-8000-00000000000b')
  AND NOT EXISTS (SELECT 1 FROM usr.ingest_batch WHERE user_id = '01900000-0000-7000-8000-00000000000b'));

-- shard rule lint: every usr table's PK leads with user_id, and no usr
-- table uses a sequence/identity column
SELECT t.check('every usr primary key leads with user_id',
  NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'usr' AND con.contype = 'p' AND NOT c.relispartition
       AND (SELECT attname FROM pg_attribute WHERE attrelid = c.oid AND attnum = con.conkey[1]) <> 'user_id'));
SELECT t.check('tenant cluster holds no catalog tables',
  NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ref'));
SELECT t.expect_error('catalog codes are format-checked',
  $$INSERT INTO usr.activity_session (user_id, started_at, session_id, ended_at, local_date, tz, activity_code, source_id)
    VALUES ('01900000-0000-7000-8000-00000000000a', t.at('16:00-05'), uuidv7(), t.at('17:00-05'),
            t.day(), 'UTC', 'drop table; --', '01900000-0000-7000-8000-0000000000d1')$$, '23514');
SELECT t.check('no sequences or identity columns in usr',
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'usr' AND (is_identity = 'YES' OR column_default LIKE 'nextval%')));
SELECT t.check('RLS enabled on every usr table',
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'usr' AND c.relkind IN ('r','p') AND NOT c.relispartition AND NOT c.relrowsecurity));

ROLLBACK;
\echo 'TENANT SMOKE TESTS PASSED (rolled back)'
