| Food category | `ref.food_group`, scheme `FDC_CATEGORY`; Branded's `brandedFoodCategory` uses scheme `FDC_BRANDED_CATEGORY` |
| Branded: brand name (brand owner when blank) | `ref.food_version.brand` |
| Branded: `gtinUpc` | `ref.food_barcode`, as GTIN-14; also the food's identity across releases |
| Branded: label serving | One portion, `1 serving (<household text>)`, when the serving is in grams |
# fdc-import — USDA FoodData Central → Atwater catalog

Loads an FDC full download into the catalog cluster. Supported datasets are **Foundation Foods**, **SR Legacy** and **Branded Foods**; Survey (FNDDS) is rejected with a clear message for now.

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

# 2. Import. The release label comes from the file name's date (2025-12-18,
#    2018-04); rerunning the same file resumes.
./fdc-import --file FoodData_Central_foundation_food_json_2025-12-18.zip
./fdc-import --file FoodData_Central_sr_legacy_food_json_2018-04.zip
```

Keep FDC's file names. The label decides which dataset release the foods land in, and the catalog is append-only, so a wrong label can't be undone: it creates a bogus release whose versions supersede the real ones. So:
- With FDC's name, `--release` is optional. If you pass one, it must equal the file name's date unless you add `--force-release`.
- A renamed file has no date to read, so `--release` is required.

The connecting user needs SET membership in `catalog_admin`. The importer switches into that role, so the catalog's append-only rules apply even if you connect as a more powerful user:

```sql
GRANT catalog_admin TO <importer_user> WITH INHERIT FALSE, SET TRUE;
```

| Flag | Meaning |
| --- | --- |
| `--file` | FDC JSON file, or the `.zip` containing exactly one JSON |
| `--release` | Release label. Defaults to the date in FDC's file name (`2025-12-18`, or `2018-04` for SR Legacy). Required when the name has no date, unless `--dry-run` |
| `--force-release` | Accept a `--release` that differs from the file name's date |
| `--dry-run` | Parse and map everything, print the report, write nothing |
| `--batch` | Foods per transaction (default 250) |
| `--limit` | Stop after N foods, for trial runs |
| `--no-set-role` | Skip `SET ROLE catalog_admin` (when connecting as it directly) |

## What it writes

| FDC | Catalog |
| --- | --- |
| Dataset + release label | `ref.dataset` (license CC0-1.0); id assigned once, never reused |
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
- **Physically impossible values are dropped, not stored.** A nutrient heavier than the food (over 100 g per 100 g, or 150 g per 100 mL, allowing a density of 1.5) or energy above 900 kcal per 100 g (pure fat) is a data-entry error: FDC Branded 2026-10-29 has sodium at 1,000,000 mg and folate at 393,000,000 µg per 100 g. A 10% allowance keeps label rounding on near-pure products (sugar, oil labelled 120 kcal per 13 g) as published. Dropped values are counted per nutrient in the report and the run log (3,017 in Branded 2026-10-29; none in Foundation or SR Legacy). The food is kept without them: unknown is honest, a clamped number is not.
- **Units convert within a dimension** (g ↔ mg ↔ µg). Values that can't convert, such as IU into µg, are skipped and reported as unit mismatches.
- **Idempotent and resumable.** Each batch commits on its own. Foods already present for the dataset release are skipped, so an interrupted run continues by running it again.
- **One file per release label.** Resuming is refused if any earlier run for that release (failed runs included) read a file with a different SHA-256. Otherwise a different download under the same label would silently keep the first file's foods, and the append-only catalog can't delete them. A different download gets its own label automatically, since FDC file names carry the release date.
- **Branded foods are keyed on their barcode.** FDC gives an updated product a new fdcId, so a valid GTIN (zero-padded to 14 digits, check digit valid) is the identity, and the next release supersedes the old version. Codes that fail the check (about 10.7k in 2026-10-29, mostly UPCs missing their check digit) store no barcode and fall back to the fdcId. Two listings with one GTIN in the same release: the second falls back to its fdcId too, so neither supersedes the other.
- **Branded nutrients are per 100 of the serving unit**: `g` gives `per_100g`, `ml` gives `per_100ml`. A volume serving has no gram weight, so those foods get no portion. About 5.4k foods give `MG`, `IU` or `MC` as the serving unit while their numbers behave like grams or millilitres; they are skipped and reported, not guessed. Energy and nutrient derivations are `label`.
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
- `test/integration.sh`: rebuilds scratch databases with `bootstrap.sh --reset` and runs the binary against `testdata/` fixtures. It checks dry run, release 1, an idempotent rerun, SR Legacy, an interrupted-then-resumed release 2 zip that supersedes release 1, a refused resume from a different file, and release labels taken from (or checked against) the file name. It also imports two Branded releases: serving units, barcodes, impossible values dropped, identity by GTIN across a dropped leading zero, and the in-release GTIN fallback. 76 checks, passing on PostgreSQL 18.7.

```bash
CATALOG_DATABASE_URL=... TENANT_DATABASE_URL=... FDC_IMPORT=./importers/fdc/fdc-import ./importers/fdc/test/integration.sh
```

For a local Unix socket, use the query form (`postgres://user@/db?host=/tmp&port=5433`); pgx rejects a percent-encoded socket path.

## Verified against real FDC files

Imported on llm (2026-11-23): Foundation 2026-10-29 (424 foods), SR Legacy 2018-04 (7,793) and Branded 2026-10-29 (434,001 read; 428,581 imported, 5,420 skipped for their serving unit; 417,871 barcodes; 3,017 impossible values dropped; 8 min 19 s at --batch 1000). The catalog is 1.27 GB after Branded. Unmapped nutrients are reported on every run; on Branded the largest are Vitamin A and Vitamin D in IU (no catalog nutrient takes IU).
