-- =====================================================================
-- Atwater bootstrap · preflight (read-only)
-- Run inside the target database with psql variables:
--   component     catalog | tenant
--   manage_roles  on | off
-- Prints one row per check: level|check|detail   (level: OK, WARN, FAIL)
-- =====================================================================
\set QUIET on
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'

WITH
params AS (
  SELECT :'component'::text AS component, :'manage_roles'::text = 'on' AS manage_roles
),
me AS (
  SELECT r.rolname, r.rolsuper, r.rolcreaterole FROM pg_roles r WHERE r.rolname = current_user
),
required_ext(component, name, required) AS (
  VALUES ('catalog','pg_trgm',true), ('tenant','btree_gist',true), ('tenant','pg_partman',false)
),
required_role(component, name) AS (
  VALUES ('catalog','catalog_ro'), ('catalog','catalog_admin'),
         ('tenant','app_rw'), ('tenant','app_ro'), ('tenant','provisioner'), ('tenant','purger')
),
checks(ord, level, check_name, detail) AS (
  -- server version
  SELECT 1 AS ord,
         CASE WHEN current_setting('server_version_num')::int >= 180000 THEN 'OK' ELSE 'FAIL' END,
         'server version',
         current_setting('server_version') || ' (need 18+)'
  -- database privilege to create schemas/objects
  UNION ALL
  SELECT 2,
         CASE WHEN has_database_privilege(current_database(), 'CREATE') THEN 'OK' ELSE 'FAIL' END,
         'create privilege on ' || current_database(),
         'connected as ' || current_user
  -- extensions
  UNION ALL
  SELECT 3,
         CASE
           WHEN i.extname IS NOT NULL THEN 'OK'
           WHEN a.name IS NULL AND e.required THEN 'FAIL'
           WHEN a.name IS NULL THEN 'WARN'
           WHEN v.trusted OR (SELECT rolsuper FROM me) THEN 'OK'
           WHEN e.required THEN 'FAIL'
           ELSE 'WARN'
         END,
         'extension ' || e.name,
         CASE
           WHEN i.extname IS NOT NULL THEN 'installed'
           WHEN a.name IS NULL AND e.required THEN 'not available on this server'
           WHEN a.name IS NULL THEN 'not available; partitions will be managed by tenant/ops/partitions.sql'
           WHEN v.trusted OR (SELECT rolsuper FROM me) THEN 'available, installable by ' || current_user
           ELSE 'available but untrusted; enable it on the platform first'
         END
    FROM required_ext e
    LEFT JOIN pg_extension i ON i.extname = e.name
    LEFT JOIN pg_available_extensions a ON a.name = e.name
    LEFT JOIN pg_available_extension_versions v ON v.name = e.name AND v.version = a.default_version
   WHERE e.component = (SELECT component FROM params)
  -- roles
  UNION ALL
  SELECT 4,
         CASE
           WHEN r.rolname IS NOT NULL THEN 'OK'
           WHEN (SELECT manage_roles FROM params) AND (SELECT rolcreaterole OR rolsuper FROM me) THEN 'OK'
           ELSE 'FAIL'
         END,
         'role ' || q.name,
         CASE
           WHEN r.rolname IS NOT NULL THEN 'exists'
           WHEN (SELECT manage_roles FROM params) AND (SELECT rolcreaterole OR rolsuper FROM me) THEN 'missing; migrations will create it'
           WHEN (SELECT manage_roles FROM params) THEN 'missing and ' || current_user || ' lacks CREATEROLE'
           ELSE 'missing; create it on the platform (manage_roles=off)'
         END
    FROM required_role q
    LEFT JOIN pg_roles r ON r.rolname = q.name
   WHERE q.component = (SELECT component FROM params)
  -- existing objects: an unmanaged, non-empty database is a stop sign
  UNION ALL
  SELECT 5,
         CASE
           WHEN to_regclass('atwater_meta.applied') IS NOT NULL THEN 'OK'
           WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('ref','usr','ops')) THEN 'FAIL'
           ELSE 'OK'
         END,
         'database state',
         CASE
           WHEN to_regclass('atwater_meta.applied') IS NOT NULL THEN 'managed by bootstrap; pending migrations will be applied'
           WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('ref','usr','ops')) THEN 'Atwater schemas present but not managed by bootstrap; reset the database'
           ELSE 'empty; full install'
         END
)
SELECT level, check_name, detail FROM checks ORDER BY ord, check_name;
