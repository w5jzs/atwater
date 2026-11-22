# Atwater

Two PostgreSQL 18 clusters with one job each:

| Cluster | Schema | Shape | Holds |
| --- | --- | --- | --- |
| **Catalog** | `ref` | One primary + read replicas, not sharded | Foods, nutrients, reference values, diet plans, activity types, metrics, lab analytes, ingest mappings |
| **Tenant** | `usr`, `ops` | Sharded by `user_id` behind the router | Everything about a person: logs, plans, targets, measurements, labs, sync feed |

The tenant cluster is the source of truth for user data, and the catalog is the source of truth for reference data. Nothing is copied between them, so there's no food database to keep in sync across shards.

**PostgreSQL 18+ only.** Both clusters use native `uuidv7()`, and every foundation migration refuses to run on an older server.

## Layout

| Path | What it holds |
| --- | --- |
| `catalog/migrations/0001_foundation.sql` | Version guard, `pg_trgm`, `ref` schema, `catalog_ro` / `catalog_admin` roles |
| `catalog/migrations/0002_ref_core.sql` | Units (UCUM), authorities + editions, datasets, nutrients, life-stage groups, reference values |
| `catalog/migrations/0003_ref_foods.sql` | Foods, immutable food versions, nutrient vectors, names, portions, barcodes, tags |
| `catalog/migrations/0004_ref_plans_activity_labs.sql` | Diet plans + versions, Compendium activity types, metrics, LOINC analytes + conversions, Open mHealth and Bluetooth GATT mappings, `ref.ble_uuid16()` |
| `catalog/migrations/0005_grants.sql` | Append-only privileges |
| `catalog/migrations/0006_import_support.sql` | `ref.food_identity` (stable food identity across releases) and `ref.import_run` (import log) |
| `catalog/seed/0001_ref_seed.sql` | Units, 7 authorities, 35 nutrients, NASEM adult 31-50 values, 17 metrics, 6 lab analytes, tags, 11 Open mHealth and 11 GATT mappings |
| `catalog/seed/0002_ref_nutrients_mn_b5_choline_folate.sql` | Manganese, pantothenic acid, choline and total folate, with NASEM adult 31-50 values; added after the first FDC dry run |
| `tenant/migrations/0001_foundation.sql` | Version guard, `btree_gist`, `usr`/`ops` schemas, roles, `ops.current_user_id()`, `ops.touch_row()` |
| `tenant/migrations/0002_usr_core.sql` | Account, physiological periods, data sources, source priority, devices, change log, outbox, `ops.record_change()` |
| `tenant/migrations/0003_usr_nutrition.sql` | Custom foods/recipes, food log, custom plans, plan assignments, overrides, resolved targets, daily totals |
| `tenant/migrations/0004_usr_hydration_activity_body.sql` | Hydration, activity sessions, body measurements, wearable samples, daily summary |
| `tenant/migrations/0005_usr_labs.sql` | Lab reports and encrypted lab results |
| `tenant/migrations/0006_usr_ingest.sql` | Ingest batches (one row per upload, checksum-deduplicated, replayable) and batch links on device-derived rows |
| `tenant/migrations/0007_grants_rls.sql` | Role privileges and row-level security |
| `tenant/migrations/0008_account_activity_level.sql` | `usr.account.activity_level`, the physical-activity category the energy target needs (design 0001) |
| `tenant/migrations/0009_target_resolution_warnings.sql` | `usr.target_resolution.warnings`, why a target is missing or far from recommended values (design 0001) |
| `tenant/ops/partitions.sql` | `ops.ensure_range_partitions()` plus a run that creates partitions around now; idempotent, no pg_partman needed |
| `bootstrap/bootstrap.sh` | One-command setup: connectivity, database existence, preflight, tracked migrations, partitions, rolled-back smoke tests |
| `bootstrap/preflight.sql` | Read-only checks run inside each database |
| `test/*_smoke_test.sql` | Smoke tests; each runs in one transaction and rolls back |
| `test/run.sh` | Local/CI: rebuilds both databases from scratch through `bootstrap.sh --reset` |
| `importers/fdc/` | Go importer for USDA FoodData Central (Foundation, SR Legacy); see its README |

## Referencing the catalog without foreign keys

Tenant columns that hold catalog ids are marked `-- [catalog ref.x]` in the DDL (e.g. `food_log_entry.food_version_id`, `nutrient_id`, `activity_code`). Integrity comes from four rules instead of FKs:

1. **The catalog is append-only.** No role has DELETE, published rows can't be edited (only lifecycle flags like `is_current`), and ids are never reused. A reference that was valid once stays valid forever.
2. **Middleware validates on write.** Every catalog id in a write is checked against the catalog (through Valkey). Food versions are immutable, so they can be cached indefinitely.
3. **Format checks in the tenant DDL** catch garbage cheaply: `nutrient_id > 0`, LOINC pattern, code-character patterns.
4. **Nightly reconciliation** collects distinct catalog ids from the tenant shards (a router fan-out) and reports any that don't exist in the catalog. Expected result: zero.

Reads that need nutrient math, such as rollups and target resolution, join in the middleware or worker: tenant rows plus cached catalog vectors.

## Ingestion: open standards first

Every external source lands through the same path. The API tier receives the payload, the raw bytes go encrypted to object storage, and a `usr.ingest_batch` row records the upload. A worker then normalizes it into tenant tables using catalog mappings, and each normalized row keeps its `ingest_batch_id`.

| Order | Path | Format | `data_source.kind` |
| --- | --- | --- | --- |
| 1 | `POST /v1/ingest/omh` | IEEE 1752 / Open mHealth JSON data points | `omh` |
| 2 | File import | FIT, GPX, TCX | `fit_file`, `gpx_file`, `tcx_file` |
| 3 | FHIR import | FHIR R4 bundles (Observation, DiagnosticReport) | `import_fhir` |
| 4 | Mobile app, direct BLE | Bluetooth SIG GATT health services | `ble_gatt` |
| 5 | Gadgetbridge importer | Gadgetbridge data export | `gadgetbridge` |
| Later | Platform and vendor APIs | HealthKit, Health Connect, Garmin, Oura, Withings, Fitbit | vendor kinds |

- **Mappings are catalog data.** `ref.omh_schema_map` maps a schema to metrics, with JSON paths to the value and unit. `ref.ble_gatt_map` maps a GATT characteristic and field to a metric. Supporting a new device type or schema is a catalog insert, not an app release.
- **Idempotent.** Re-sending the same bytes from the same source is rejected by `UNIQUE (user_id, source_id, payload_sha256)`. Individual records dedupe on `(source_id, external_id)`.
- **Replayable.** `normalizer_version` records which mapping produced the rows. Reprocessing a batch with a newer normalizer, or withdrawing a bad import, works on the batch as a unit.

## Tenant conventions

**Shard rules (enforced by lint checks in the smoke test):**
1. `user_id uuid NOT NULL` leads every `usr` primary key.
2. FKs between `usr` tables are composite `(user_id, …)`. They stay shard-local and make cross-user references impossible.
3. No sequences or identity columns. Row ids are UUIDv7, client-generated for offline-created rows.
4. Partitioned tables include the partition column in the PK.
5. Every middleware query filters on `user_id`.

**Identity.** `usr.account.user_id` comes only from the stateless ID mapper's `user.provisioned` event. Only `provisioner` can insert accounts, and the app role can't touch keys, the sync cursor or the id.

**Immutability.** `usr.custom_food_version` (+ nutrients, ingredients) and `usr.custom_plan_version` are insert-only, matching `ref.food_version` in the catalog. History never changes when a food or recipe is edited. A custom food's header and first version must be inserted in the same transaction (deferred FK).

**Enumerations** are `text` + `CHECK`, never Postgres `ENUM`, because adding enum values across many shards is painful.

**Units and time.** Values are stored canonically using UCUM codes, with as-entered values kept where users type them. Every event stores `timestamptz` plus `local_date` and `tz` at entry time. Daily rollups and targets key on `local_date`.

**Encryption.** Columns ending `_enc` are encrypted in middleware with the user's DEK (`usr.account.wrapped_dek`). Lab values are fully encrypted; LOINC codes stay plaintext. Destroying the DEK crypto-shreds the user's encrypted data.

**Mutable rows** carry `created_at`, `updated_at`, `version` (optimistic concurrency) and `deleted_at` (soft delete), maintained by `ops.touch_row()`, which also blocks `user_id` changes.

**Sync.** `ops.record_change()` appends to `usr.change_log` with a per-user monotonic `seq`. Clients pull `WHERE seq > cursor`. Soft deletes publish as `op = 'delete'`, and `entity_ts` carries the partition key.

## Roles

| Cluster | Role | Can do |
| --- | --- | --- |
| Catalog | `catalog_ro` | Read `ref` (middleware, workers, search indexer; usually on replicas) |
| Catalog | `catalog_admin` | Insert new releases; flip `is_current` / `superseded_by` / `retired_at`; no DELETE |
| Tenant | `app_rw` | Read/write `usr` under RLS; no DELETE; profile columns only on `usr.account`; insert-only on version tables |
| Tenant | `app_ro` | Read `usr` under RLS (replicas) |
| Tenant | `provisioner` | Insert `usr.account` and the user's manual `data_source` |
| Tenant | `purger` | Hard-delete a user's rows after `user.deleted` (cascades) |

Middleware must `SET LOCAL app.user_id = '<uid claim>'` at the start of every tenant transaction. RLS denies everything otherwise.

## Partitioning (tenant)

Partitioned parents ship with a `DEFAULT` partition. pg_partman owns the real ones:

| Table | Key | Interval |
| --- | --- | --- |
| `food_log_entry`, `hydration_entry`, `activity_session`, `body_measurement`, `change_log` | event time | monthly |
| `observation_sample` | `observed_at` | daily |
| `daily_target`, `daily_nutrient_total`, `daily_summary` | `local_date` | yearly |

`tenant/ops/partitions.sql` creates them without pg_partman (bootstrap runs it every time; schedule it daily on staging). Keep DEFAULT partitions empty and alert if they ever hold rows. `change_log` retention is about 90 days; older devices do a full resync.

## Bootstrap (staging and local)

One command takes two empty, or partly migrated, databases to the current schema and proves it works:

```bash
export CATALOG_DATABASE_URL='postgres://USER:PASS@HOST:5432/atwater_catalog?sslmode=require'
export TENANT_DATABASE_URL='postgres://USER:PASS@HOST:5432/atwater_tenant?sslmode=require'
./bootstrap/bootstrap.sh                    # databases must already exist
./bootstrap/bootstrap.sh --create-missing   # create them if the user has CREATEDB
./bootstrap/bootstrap.sh --preflight-only   # check everything, change nothing
```

| Step | What it does | Stops when |
| --- | --- | --- |
| Connectivity | Connects to the maintenance database (`ATWATER_MAINTENANCE_DB`, default `postgres`) on each server | A server is unreachable |
| Databases | Confirms both target databases exist; `--create-missing` creates them, `--reset` drops and recreates them | A database is missing and there's no flag or CREATEDB |
| Preflight | Server version 18+, CREATE privilege, extensions (`pg_trgm`, `btree_gist`; `pg_partman` optional), roles, database state | Any check fails; nothing has been changed yet |
| Migrate | Applies pending files in order and records each one's SHA-256 in `atwater_meta.applied` | An applied file was edited later (reset, or write a new migration) |
| Partitions | Creates tenant partitions around now (monthly, daily for samples, yearly for rollups) | Never; idempotent |
| Smoke tests | Runs both suites inside a transaction and rolls back, so nothing is left behind | Any check fails |

**Roles.** With `ATWATER_MANAGE_ROLES=auto` (the default), migrations create the NOLOGIN roles when the bootstrap user has CREATEROLE. On a platform that manages roles, create these roles there first and set `ATWATER_MANAGE_ROLES=off`; migrations then only verify they exist and apply grants:
- catalog: `catalog_ro`, `catalog_admin`
- tenant: `app_rw`, `app_ro`, `provisioner`, `purger`

The smoke tests switch into these roles, so the bootstrap user needs SET membership in them. Bootstrap grants it (`WITH INHERIT FALSE, SET TRUE`) when it holds ADMIN on the role, and otherwise stops with a message.

**Safety.**
- `--reset` requires `ATWATER_CONFIRM_RESET="<catalog_db>,<tenant_db>"`.
- A database that already holds Atwater schemas but wasn't set up by bootstrap is refused.
- Passwords are redacted in all output.
- The smoke tests never commit.

**Validated** on PostgreSQL 18.4 as a non-superuser admin (CREATEDB + CREATEROLE). Scenarios covered: databases missing (stops), platform-managed roles missing (stops in preflight), full install (16 + 27 checks), idempotent rerun with no leftovers, an edited migration (stops), reset with and without confirmation, an unmanaged database (stops), and password redaction.

**Local/CI:** `test/run.sh` points `bootstrap.sh --reset` at disposable databases.

## Open items

- Diet-plan `rules` JSON Schema (v1) and the target-resolution algorithm.
- FoodData Central importer: built and tested on fixtures; dry-run against the real Foundation and SR Legacy files before the first import.
- Catalog import jobs: Open Food Facts (keep ODbL data isolated), Compendium 2024, LOINC, other authorities, and the IEEE 1752 (`ieee` namespace) schema mappings.
- Verify the seeded Open mHealth value paths against the published schema versions.
- The nightly reconciliation job (orphaned catalog references).
- Router topology: `usr.*` sharded on `user_id`, `ops.*` deployed to every shard.
- Seeded NASEM values are a starter set. Verify them against the source tables before production.
