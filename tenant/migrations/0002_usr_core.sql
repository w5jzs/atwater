-- =====================================================================
-- Atwater tenant · 0002 · tenant core: account, provenance, devices,
-- sync change log, outbox
--
-- Shard rules for every usr table:
--   1. user_id uuid NOT NULL leads every primary key.
--   2. No FK, unique constraint or join crosses users; FKs between usr
--      tables are composite (user_id, ...) so they stay shard-local AND
--      make it impossible to reference another user's rows.
--   3. No sequences/serial. Row ids are UUIDv7 (client-generated for
--      offline-created rows, validated server-side).
--   4. Partitioned tables carry the partition column in the PK.
--
-- Catalog references: columns marked [catalog ref.x] hold ids from the
-- separate catalog cluster. There are no cross-cluster FKs; middleware
-- validates every catalog id on write (against a cached catalog) and a
-- nightly reconciliation job reports any orphan. Catalog ids are never
-- deleted or reused, so a validated reference stays valid.
-- =====================================================================
BEGIN;

CREATE TABLE usr.account (
  user_id         uuid PRIMARY KEY,              -- minted ONLY by the stateless ID mapper (auth domain)
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         int  NOT NULL DEFAULT 1,
  -- Inputs to target resolution
  birth_date      date CHECK (birth_date > '1900-01-01'),
  reference_sex   text CHECK (reference_sex IN ('female','male')),  -- selects sex-specific reference values
  height_cm       numeric(5,1) CHECK (height_cm BETWEEN 30 AND 272),
  country         char(2),
  locale          text NOT NULL DEFAULT 'en-US',
  tz              text NOT NULL DEFAULT 'UTC',   -- IANA zone; validated by middleware
  authority_code  text NOT NULL DEFAULT 'NASEM_DRI' CHECK (authority_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),  -- [catalog ref.authority]
  unit_system     text NOT NULL DEFAULT 'imperial' CHECK (unit_system IN ('imperial','metric')),
  -- Envelope encryption: per-user data key, wrapped by a KMS/Vault key.
  -- Destroying wrapped_dek crypto-shreds every *_enc column and object.
  kek_id          text  NOT NULL,
  wrapped_dek     bytea NOT NULL,
  -- Per-user monotonic sync cursor (bumped by ops.record_change).
  sync_seq        bigint NOT NULL DEFAULT 0,
  deleted_at      timestamptz
);

-- Pregnancy/lactation change reference values; effective-dated, never overlapping.
CREATE TABLE usr.physiological_period (
  user_id     uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  period_id   uuid NOT NULL,
  state       text NOT NULL CHECK (state IN ('pregnant','lactating')),
  valid       daterange NOT NULL CHECK (NOT isempty(valid)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  version     int NOT NULL DEFAULT 1,
  deleted_at  timestamptz,
  PRIMARY KEY (user_id, period_id),
  EXCLUDE USING gist (user_id WITH =, valid WITH &&) WHERE (deleted_at IS NULL)
);

-- Provenance for every observation: manual entry, imports, devices.
CREATE TABLE usr.data_source (
  user_id               uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  source_id             uuid NOT NULL,
  kind                  text NOT NULL CHECK (kind IN (
                          -- open standards first
                          'manual','omh','ble_gatt','gadgetbridge','fit_file','gpx_file','tcx_file',
                          'import_fhir','import_csv',
                          -- proprietary platforms and clouds (later)
                          'healthkit','health_connect','garmin','oura','withings','fitbit','other')),
  label                 text,
  device_model          text,
  external_account_ref  text,                    -- vendor account id; never a credential
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  version               int NOT NULL DEFAULT 1,
  deleted_at            timestamptz,
  PRIMARY KEY (user_id, source_id)
);
CREATE UNIQUE INDEX data_source_one_manual ON usr.data_source (user_id) WHERE kind = 'manual';

-- Which source wins when two report the same metric for the same window.
CREATE TABLE usr.source_priority (
  user_id      uuid NOT NULL,
  metric_code  text NOT NULL CHECK (metric_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),  -- [catalog ref.metric]
  source_id    uuid NOT NULL,
  priority     smallint NOT NULL CHECK (priority > 0),   -- 1 = highest
  PRIMARY KEY (user_id, metric_code, source_id),
  UNIQUE (user_id, metric_code, priority),
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source ON DELETE CASCADE
);

CREATE TABLE usr.client_device (
  user_id        uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  device_id      uuid NOT NULL,                  -- generated on install
  platform       text NOT NULL CHECK (platform IN ('ios','android','web')),
  app_version    text,
  last_pull_seq  bigint NOT NULL DEFAULT 0,
  last_seen_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);

-- Sync feed: one row per change to a synced entity, ordered by a per-user
-- sequence. Clients pull WHERE seq > cursor. Retention ~90 days; a client
-- older than retention does a full resync.
CREATE TABLE usr.change_log (
  user_id     uuid NOT NULL,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  seq         bigint NOT NULL,
  entity      text NOT NULL,
  entity_id   uuid NOT NULL,
  entity_ts   timestamptz,                       -- partition key of the entity, when it has one
  op          text NOT NULL CHECK (op IN ('upsert','delete')),
  PRIMARY KEY (user_id, changed_at, seq)
) PARTITION BY RANGE (changed_at);
CREATE INDEX change_log_cursor ON usr.change_log (user_id, seq);
CREATE TABLE usr.change_log_default PARTITION OF usr.change_log DEFAULT;

-- Transactional outbox for domain events (rollup requests, exports,
-- deletion fan-out). One relay per shard publishes and stamps published_at.
CREATE TABLE usr.outbox (
  user_id       uuid NOT NULL,
  event_id      uuid NOT NULL DEFAULT uuidv7(),
  topic         text NOT NULL,
  payload       jsonb NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  published_at  timestamptz,
  PRIMARY KEY (user_id, event_id)
);
CREATE INDEX outbox_unpublished ON usr.outbox (created_at) WHERE published_at IS NULL;

-- AFTER INSERT/UPDATE on synced tables. Args: entity name, id column,
-- [timestamp column used as partition key]. Soft delete (deleted_at set)
-- is published as op='delete'. SECURITY DEFINER so it can bump the cursor
-- regardless of the caller's grants; search_path pinned.
CREATE OR REPLACE FUNCTION ops.record_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_row jsonb := to_jsonb(NEW);
  v_seq bigint;
BEGIN
  UPDATE usr.account SET sync_seq = sync_seq + 1
   WHERE user_id = NEW.user_id
   RETURNING sync_seq INTO v_seq;
  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'unknown user_id %', NEW.user_id USING ERRCODE = 'foreign_key_violation';
  END IF;

  INSERT INTO usr.change_log (user_id, seq, entity, entity_id, entity_ts, op)
  VALUES (
    NEW.user_id, v_seq, TG_ARGV[0],
    (v_row ->> TG_ARGV[1])::uuid,
    CASE WHEN TG_NARGS > 2 THEN (v_row ->> TG_ARGV[2])::timestamptz END,
    CASE WHEN v_row ->> 'deleted_at' IS NOT NULL THEN 'delete' ELSE 'upsert' END);
  RETURN NULL;
END $$;

-- account: touch only on real profile edits, not on sync_seq bumps.
CREATE TRIGGER account_touch BEFORE UPDATE ON usr.account
  FOR EACH ROW WHEN (NEW.sync_seq = OLD.sync_seq) EXECUTE FUNCTION ops.touch_row();

CREATE TRIGGER touch BEFORE UPDATE ON usr.physiological_period FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.physiological_period
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('physiological_period','period_id');

CREATE TRIGGER touch BEFORE UPDATE ON usr.data_source FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.data_source
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('data_source','source_id');

COMMIT;
