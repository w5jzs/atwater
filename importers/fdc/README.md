# fdc-import — USDA FoodData Central → Atwater catalog

Loads an FDC full download into the catalog cluster. Supported datasets are **Foundation Foods** and **SR Legacy**; Branded and Survey (FNDDS) are rejected with a clear message for now.

## Build

Go 1.23+.

```bash
cd importers/fdc
go mod tidy          # first time: fetches pgx and writes go.sum
go test ./...
go build -o fdc-import .
```

## Run

Download the JSON files (or the `.zip` they ship in) from https://fdc.nal.usda.gov/download-datasets, then:

```bash
export CATALOG_DATABASE_URL='postgres://USER:PASS@HOST:5432/atwater_catalog?sslmode=require'

# 1. Check mappings against the real file. Writes nothing.
./fdc-import --file FoodData_Central_foundation_food_json_2025-12-18.zip --dry-run

# 2. Import. --release labels this download; reruns with the same label resume.
./fdc-import --file FoodData_Central_foundation_food_json_2025-12-18.zip --release 2025-12
./fdc-import --file FoodData_Central_sr_legacy_food_json_2018-04.zip   --release 2018-04
```

The connecting user needs SET membership in `catalog_admin`. The importer switches into that role, so the catalog's append-only rules apply even if you connect as a more powerful user:

```sql
GRANT catalog_admin TO <importer_user> WITH INHERIT FALSE, SET TRUE;
```

| Flag | Meaning |
| --- | --- |
| `--file` | FDC JSON file, or the `.zip` containing exactly one JSON |
| `--release` | Release label, e.g. `2025-12`. Required unless `--dry-run` |
| `--dry-run` | Parse and map everything, print the report, write nothing |
| `--batch` | Foods per transaction (default 250) |
| `--limit` | Stop after N foods, for trial runs |
| `--no-set-role` | Skip `SET ROLE catalog_admin` (when connecting as it directly) |

## What it writes

| FDC | Catalog |
| --- | --- |
| Dataset + `--release` | `ref.dataset` (license CC0-1.0); id assigned once, never reused |
| NDB number (fdcId if absent) | `ref.food_identity` → `ref.food`: the same food across releases |
| Each food | One immutable `ref.food_version` (source key = fdcId) |
| Food nutrients | `ref.food_nutrient`, per 100 g, converted to each nutrient's canonical unit |
| Description | `ref.food_name` (en-US, primary) |
| Food portions | `ref.food_portion` with gram weights; FDC's first portion is the default |
| Food category | `ref.food_group`, scheme `FDC_CATEGORY` |
| Every run | `ref.import_run` with file name, SHA-256, status and the stats below |

## Rules worth knowing

- **Energy is stored as published, never recomputed.** The importer prefers FDC's Energy (208), then Atwater-specific (958), then Atwater-general (957). It records which in `energy_method` and keeps the food's calorie conversion factors. kJ (268) is ignored because kcal is the canonical unit.
- **Nutrients map by FDC nutrient number** via `ref.nutrient.fdc_nutrient_number`. Foundation's total sugars (269.3) is aliased to 269. Anything unmapped is counted and reported, not dropped silently; add the nutrient to `ref.nutrient` to start importing it.
- **Units convert within a dimension** (g ↔ mg ↔ µg). Values that can't convert, such as IU into µg, are skipped and reported as unit mismatches.
- **Idempotent and resumable.** Each batch commits on its own. Foods already present for the dataset release are skipped, so an interrupted run continues by running it again.
- **New releases supersede, history stays.** Importing a newer release adds new versions under the same food, marks the old versions not current, and points them at their replacement. Logged meals keep referencing the version they were logged against. A food missing from a newer release stays current.

## Example report (dry run on the test fixture)

```
dataset FDC_FOUNDATION (FoundationFoods), file foundation_r1.json, sha256 4b05815a1629

dry run (nothing written) finished in 0s
  foods read            2
  nutrient rows         9 (excluding energy)
  portion rows          3 (skipped 1 without grams or a label)
  foods without energy  1
  energy methods        atwater_specific ×1, other ×1
  unit mismatches       301 IU->mg ×1
  unmapped nutrients    1 distinct; most common: 511 Tryptophan ×1
```

## Tests

- `go test ./...`: unit tests for energy selection, nutrient and unit mapping, portions, identity keys and stream parsing.
- `test/integration.sh`: rebuilds scratch databases with `bootstrap.sh --reset` and runs the binary against `testdata/` fixtures. It checks dry run, release 1, an idempotent rerun, SR Legacy, and an interrupted-then-resumed release 2 zip that supersedes release 1. 38 checks, passing on PostgreSQL 18.4.

```bash
CATALOG_DATABASE_URL=... TENANT_DATABASE_URL=... FDC_IMPORT=./importers/fdc/fdc-import ./importers/fdc/test/integration.sh
```

For a local Unix socket, use the query form (`postgres://user@/db?host=/tmp&port=5433`); pgx rejects a percent-encoded socket path.

## Not yet verified against real FDC files

The fixtures follow FDC's published JSON layout, but the real downloads couldn't be fetched while this was built. Run `--dry-run` on the actual Foundation and SR Legacy files first and check that:

- foods read matches the dataset size;
- the energy-method split looks plausible and few foods lack energy;
- no unexpected unit mismatches appear;
- the unmapped list holds only nutrients we haven't chosen to track (amino acids, individual fatty acids and so on).
