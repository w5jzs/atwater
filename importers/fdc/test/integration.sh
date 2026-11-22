#!/usr/bin/env bash
# FDC importer integration test. Rebuilds scratch databases with bootstrap
# (--reset), then runs the importer against FDC-format fixtures and checks
# the catalog. Point the URLs at a disposable PostgreSQL 18 server.
#   CATALOG_DATABASE_URL=postgres://.../atwater_catalog_test \
#   TENANT_DATABASE_URL=postgres://.../atwater_tenant_test \
#   FDC_IMPORT=/path/to/fdc-import  ./importers/fdc/test/integration.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DATA="$HERE/../testdata"
: "${CATALOG_DATABASE_URL:?}" "${TENANT_DATABASE_URL:?}" "${FDC_IMPORT:?path to the built fdc-import binary}"

cat_db="$(sed -E 's#^[^/]*//[^/]*/([^?]*).*#\1#' <<<"$CATALOG_DATABASE_URL")"
ten_db="$(sed -E 's#^[^/]*//[^/]*/([^?]*).*#\1#' <<<"$TENANT_DATABASE_URL")"
ATWATER_CONFIRM_RESET="$cat_db,$ten_db" "$ROOT/bootstrap/bootstrap.sh" --reset --skip-tests >/dev/null
echo "bootstrapped $cat_db"
# The importer writes as catalog_admin; the connecting user needs SET (not inherit) membership.
psql "$CATALOG_DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "DO \$\$ BEGIN IF NOT pg_has_role(current_user, 'catalog_admin', 'SET') THEN
        GRANT catalog_admin TO CURRENT_USER WITH INHERIT FALSE, SET TRUE; END IF; END \$\$"

pass=0
sql() { psql "$CATALOG_DATABASE_URL" -X -q -tA -v ON_ERROR_STOP=1 -c "$1"; }
check() {   # label  expected  sql
  local got; got="$(sql "$3")"
  if [[ "$got" == "$2" ]]; then echo "  PASS $1"; pass=$((pass+1))
  else echo "  FAIL $1: expected [$2], got [$got]" >&2; exit 1; fi
}
imp() { "$FDC_IMPORT" "$@" >/tmp/fdc_import.out 2>&1 || { cat /tmp/fdc_import.out >&2; return 1; }; }
imp_fails() { if "$FDC_IMPORT" "$@" >/tmp/fdc_import.out 2>&1; then echo "  FAIL expected failure: $*" >&2; exit 1; fi; }
out_has() { grep -qE "$2" /tmp/fdc_import.out && { echo "  PASS $1"; pass=$((pass+1)); } || { echo "  FAIL $1" >&2; cat /tmp/fdc_import.out >&2; exit 1; }; }

V="ref.food_version v JOIN ref.dataset d USING (dataset_id)"
nut() { echo "(SELECT fn.amount::float8 FROM ref.food_nutrient fn JOIN ref.nutrient n USING (nutrient_id)
             WHERE fn.food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '$1') AND n.code = '$2')"; }

echo "-- input validation"
imp_fails --file "$DATA/branded_unsupported.json" --release x
out_has "unsupported dataset rejected" "not supported yet"
imp_fails --file "$DATA/foundation_r1.json"
out_has "--release required for a real import" "release is required"

echo "-- dry run writes nothing"
imp --file "$DATA/foundation_r1.json" --dry-run
out_has "dry run reports foods read" "foods read +2"
out_has "dry run reports unmapped nutrients" "511 Tryptophan"
check "no versions after dry run" 0 "SELECT count(*) FROM ref.food_version"
check "no dataset row after dry run" 0 "SELECT count(*) FROM ref.dataset"

echo "-- Foundation release 1"
imp --file "$DATA/foundation_r1.json" --release 2025-04
check "two food versions" 2 "SELECT count(*) FROM $V WHERE d.code = 'FDC_FOUNDATION'"
check "hummus energy from Atwater-specific (958)" "166|atwater_specific" \
  "SELECT $(nut 321358 energy)||'|'||energy_method FROM ref.food_version WHERE source_key = '321358'"
check "specific Atwater factors stored" "3.470|8.370|4.070" \
  "SELECT protein_kcal_per_g||'|'||fat_kcal_per_g||'|'||carb_kcal_per_g FROM ref.food_version WHERE source_key = '321358'"
check "Foundation sugars (269.3) mapped" 0.34 "SELECT $(nut 321358 sugars)"
check "derivation mapped" analytical \
  "SELECT derivation FROM ref.food_nutrient fn JOIN ref.nutrient n USING (nutrient_id)
    WHERE n.code = 'protein' AND food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '321358')"
check "egg without energy has no energy row" "" "SELECT $(nut 748967 energy)"
check "egg energy method is other" other "SELECT energy_method FROM ref.food_version WHERE source_key = '748967'"
check "phosphorus converted g -> mg" 198 "SELECT $(nut 748967 phosphorus)"
check "IU iron skipped, not stored" "" "SELECT $(nut 748967 iron)"
check "zero-gram portion skipped; tbsp is default with UCUM unit" "1 tbsp|[tbs_us]|15.000|true;1 cup|[cup_us]|246.000|false" \
  "SELECT string_agg(label||'|'||coalesce(unit_code,'')||'|'||gram_weight||'|'||is_default, ';' ORDER BY sort_order)
     FROM ref.food_portion WHERE food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '321358')"
check "category became a food group" "Legumes and Legume Products" \
  "SELECT g.name FROM ref.food_version v JOIN ref.food_group g ON (g.scheme, g.group_code) = (v.group_scheme, v.group_code)
    WHERE v.source_key = '321358'"
check "identity keys: NDB when present, fdcId otherwise" "fdc:748967;ndb:16158" \
  "SELECT string_agg(identity_key, ';' ORDER BY identity_key) FROM ref.food_identity WHERE source_family = 'FDC_FOUNDATION'"
check "primary en-US name" "Hummus, commercial" \
  "SELECT name FROM ref.food_name WHERE is_primary AND locale = 'en-US'
      AND food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '321358')"
check "import run logged as done" "done|2" "SELECT status||'|'||(stats->>'foods_inserted') FROM ref.import_run ORDER BY started_at LIMIT 1"

echo "-- rerun is idempotent"
imp --file "$DATA/foundation_r1.json" --release 2025-04
out_has "rerun skips loaded foods" "already loaded +2"
check "still two versions" 2 "SELECT count(*) FROM ref.food_version"
check "one dataset row reused" 1 "SELECT count(*) FROM ref.dataset WHERE code = 'FDC_FOUNDATION'"

echo "-- SR Legacy"
imp --file "$DATA/sr_legacy.json" --release 2018-04
check "butter: published 208 with specific factors" "717|atwater_specific" \
  "SELECT $(nut 173410 energy)||'|'||energy_method FROM ref.food_version WHERE source_key = '173410'"
check "olive oil: 4/9/4 recorded as general" atwater_general "SELECT energy_method FROM ref.food_version WHERE source_key = '171413'"
check "SR Legacy kind is generic" generic "SELECT DISTINCT food_kind FROM $V WHERE d.code = 'FDC_SR_LEGACY'"
check "modifier-only portions labelled, first is default" '1 pat (1" sq, 1/3" high)|true' \
  "SELECT label||'|'||is_default FROM ref.food_portion
    WHERE food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '173410') ORDER BY sort_order LIMIT 1"

echo "-- Foundation release 2 (zip), interrupted then resumed"
imp --file "$DATA/foundation_r2.zip" --release 2025-12 --limit 1
check "partial run stored one food" 1 "SELECT count(*) FROM $V WHERE d.release_label = '2025-12'"
imp --file "$DATA/foundation_r2.zip" --release 2025-12
out_has "resume skipped the loaded food" "already loaded +1"
check "release 2 complete" 2 "SELECT count(*) FROM $V WHERE d.release_label = '2025-12'"
check "hummus keeps one food identity across releases" 1 \
  "SELECT count(DISTINCT food_id) FROM ref.food_version WHERE source_key IN ('321358','2000001')"
check "old hummus superseded by new" "false|true" \
  "SELECT o.is_current||'|'||(o.superseded_by = n.food_version_id) FROM ref.food_version o, ref.food_version n
    WHERE o.source_key = '321358' AND n.source_key = '2000001'"
check "new hummus is current with new energy" "true|170" \
  "SELECT is_current||'|'||$(nut 2000001 energy) FROM ref.food_version WHERE source_key = '2000001'"
check "egg (absent from release 2) stays current" t "SELECT is_current FROM ref.food_version WHERE source_key = '748967'"
check "exactly one current version per food" 0 \
  "SELECT count(*) FROM (SELECT food_id FROM ref.food_version WHERE is_current GROUP BY food_id HAVING count(*) > 1) x"

echo "-- resume refuses a different file under a used release label"
imp_fails --file "$DATA/foundation_r1.json" --release 2025-12
out_has "different file for 2025-12 refused" "already imported from a different file \(foundation_r2.zip"
check "refused import wrote no versions" 2 "SELECT count(*) FROM $V WHERE d.release_label = '2025-12'"
check "refused import logged no run" 5 "SELECT count(*) FROM ref.import_run"
imp --file "$DATA/foundation_r2.zip" --release 2025-12
out_has "original file still resumes" "already loaded +2"

echo "-- run log"
check "every import run recorded" 6 "SELECT count(*) FROM ref.import_run"
check "no run left running" 0 "SELECT count(*) FROM ref.import_run WHERE status <> 'done'"
check "run log keeps file names, never local paths" 0 "SELECT count(*) FROM ref.import_run WHERE source_file LIKE '%/%'"

echo "ALL $pass FDC IMPORTER CHECKS PASSED"
