-- =====================================================================
-- Atwater catalog · 0006 · import support
--
-- ref.food_identity ties a source's stable key (FDC ndbNumber, OFF
-- barcode, CoFID code) to one ref.food, so a new release of a dataset
-- adds a new food_version under the same food instead of a new food.
-- ref.import_run logs every import for audit and troubleshooting.
-- =====================================================================
BEGIN;

CREATE TABLE ref.food_identity (
  source_family  text NOT NULL,                 -- dataset code family: FDC_FOUNDATION, FDC_SR_LEGACY ...
  identity_key   text NOT NULL,                 -- 'ndb:01001' or 'fdc:747997'
  food_id        uuid NOT NULL REFERENCES ref.food,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_family, identity_key)
);
CREATE INDEX food_identity_food ON ref.food_identity (food_id);

CREATE TABLE ref.import_run (
  run_id       uuid PRIMARY KEY DEFAULT uuidv7(),
  importer     text NOT NULL,                   -- 'fdc'
  dataset_id   smallint NOT NULL REFERENCES ref.dataset,
  source_file  text NOT NULL,                   -- file name only, never a full local path
  source_sha256 bytea NOT NULL CHECK (length(source_sha256) = 32),
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  status       text NOT NULL DEFAULT 'running' CHECK (status IN ('running','done','failed')),
  stats        jsonb NOT NULL DEFAULT '{}'
);

GRANT SELECT ON ref.food_identity, ref.import_run TO catalog_ro, catalog_admin;
GRANT INSERT ON ref.food_identity, ref.import_run TO catalog_admin;
GRANT UPDATE (finished_at, status, stats) ON ref.import_run TO catalog_admin;

COMMIT;
