-- =====================================================================
-- Atwater tenant · 0001 · extensions, schemas, roles, shared functions
-- Cluster: tenant (sharded by user_id behind the router).
-- Requires PostgreSQL 18+ (native uuidv7()). Every object here must exist
-- on every shard.
-- =====================================================================
BEGIN;

DO $$
BEGIN
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE EXCEPTION 'Atwater requires PostgreSQL 18 or newer (found %)', current_setting('server_version');
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- EXCLUDE constraints mixing uuid/smallint with ranges

CREATE SCHEMA IF NOT EXISTS usr;   -- tenant data: every table keyed and sharded by user_id
CREATE SCHEMA IF NOT EXISTS ops;   -- shared functions (triggers, session helpers)

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
  FOREACH r IN ARRAY ARRAY['app_rw','app_ro','provisioner','purger'] LOOP
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

-- The verified user for this transaction. Middleware runs
--   SET LOCAL app.user_id = '<uid claim from the Clerk token>'
-- at the start of every transaction; RLS policies read it.
CREATE OR REPLACE FUNCTION ops.current_user_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;

-- BEFORE UPDATE on mutable usr tables: bump version + updated_at, and
-- forbid moving a row to another user.
CREATE OR REPLACE FUNCTION ops.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'user_id is immutable' USING ERRCODE = 'check_violation';
  END IF;
  NEW.updated_at := now();
  NEW.version    := OLD.version + 1;
  RETURN NEW;
END $$;

COMMIT;
