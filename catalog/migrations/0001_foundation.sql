-- =====================================================================
-- Atwater catalog · 0001 · extensions, schema, roles
-- Cluster: catalog (its own PostgreSQL cluster: one primary + read
-- replicas; not sharded, not copied into tenant shards).
-- Requires PostgreSQL 18+ (native uuidv7()).
-- =====================================================================
BEGIN;

DO $$
BEGIN
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE EXCEPTION 'Atwater requires PostgreSQL 18 or newer (found %)', current_setting('server_version');
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fallback food-name search (primary search is the external index)

CREATE SCHEMA IF NOT EXISTS ref;

--   catalog_ro     middleware, workers, search indexer (read-only, usually on replicas)
--   catalog_admin  import jobs: insert new releases, flip lifecycle columns
--
-- Roles: created here when atwater.manage_roles is 'on' (default). On managed
-- platforms that create roles out of band, run with
--   PGOPTIONS='-c atwater.manage_roles=off'
-- and this block only verifies the roles exist.
DO $$
DECLARE
  r       text;
  manage  boolean := coalesce(nullif(current_setting('atwater.manage_roles', true), ''), 'on') <> 'off';
  missing text[]  := '{}';
BEGIN
  FOREACH r IN ARRAY ARRAY['catalog_ro','catalog_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      IF manage THEN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
      ELSE
        missing := missing || r;
      END IF;
    END IF;
  END LOOP;
  IF cardinality(missing) > 0 THEN
    RAISE EXCEPTION 'required roles missing and atwater.manage_roles=off: %', array_to_string(missing, ', ')
      USING HINT = 'Create them on the platform (NOLOGIN), then rerun.';
  END IF;
END $$;

COMMIT;
