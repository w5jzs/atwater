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
imp_fails --file "$DATA/survey_unsupported.json" --release x
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
imp --file "$DATA/foundation_r1.json" --dry-run
dry_rows="$(sed -nE 's/^ +nutrient rows +([0-9]+).*/\1/p' /tmp/fdc_import.out)"
imp --file "$DATA/foundation_r1.json" --release 2025-04
out_has "import reports the same nutrient rows as the dry run" "nutrient rows +$dry_rows \(excluding energy\)"
check "reported nutrient rows match the catalog (excluding energy)" "$dry_rows" \
  "SELECT count(*) FROM ref.food_nutrient fn JOIN $V USING (food_version_id) JOIN ref.nutrient n USING (nutrient_id)
    WHERE d.release_label = '2025-04' AND n.code <> 'energy'"
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

echo "-- release label defaults to the file name's date"
# Same bytes as foundation_r2.zip (imported above as 2025-12), under FDC's naming.
DATED=/tmp/FoodData_Central_foundation_food_json_2025-12-18.zip
cp "$DATA/foundation_r2.zip" "$DATED"
runs_before="$(sql "SELECT count(*) FROM ref.import_run")"
imp_fails --file "$DATED" --release 2026-10
out_has "release contradicting the file name refused" "doesn't match the file name's release date \"2025-12-18\""
check "refused label created no dataset" 0 "SELECT count(*) FROM ref.dataset WHERE release_label = '2026-10'"
imp --file "$DATED" --release 2025-12 --force-release
out_has "--force-release accepts the deliberate label" "overriding file name date 2025-12-18"
out_has "forced label resumes the same file" "already loaded +2"
imp --file "$DATED"
out_has "label taken from the file name" "release 2025-12-18 \(from file name\)"
check "dataset created under the file name's date" 2 \
  "SELECT count(*) FROM $V WHERE d.code = 'FDC_FOUNDATION' AND d.release_label = '2025-12-18'"
check "only the two accepted runs were logged" $((runs_before + 2)) "SELECT count(*) FROM ref.import_run"
rm -f "$DATED"

echo "-- Branded release 1"
BV="$V WHERE d.code = 'FDC_BRANDED'"
bc() { echo "(SELECT string_agg(gtin, ',' ORDER BY gtin) FROM ref.food_barcode
               WHERE food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '$1'))"; }
imp --file "$DATA/branded_r1.json" --dry-run
dry_rows="$(sed -nE 's/^ +nutrient rows +([0-9]+).*/\1/p' /tmp/fdc_import.out)"
out_has "dry run counts the MG-serving food as skipped" 'foods skipped +1: serving unit "MG"'
out_has "dry run counts barcodes" 'barcodes \(GTIN-14\) +4 \(skipped 1 invalid\)'
imp --file "$DATA/branded_r1.json" --release 2026-10
out_has "import reports the dry run's nutrient rows" "nutrient rows +$dry_rows \(excluding energy\)"
out_has "import reports the volume-basis food" "foods per 100 mL +1"
out_has "import reports the identity fallback" "identity fallbacks +1"
check "six branded versions (MG serving skipped)" 6 "SELECT count(*) FROM $BV"
check "skipped food left no trace" 0 "SELECT count(*) FROM ref.food_version WHERE source_key = '3000003'"
check "kind, brand (owner when no brand name), basis, label energy" "branded|MICHELE'S|per_100g|label|500" \
  "SELECT food_kind||'|'||brand||'|'||nutrient_basis||'|'||energy_method||'|'||$(nut 3000001 energy) FROM ref.food_version WHERE source_key = '3000001'"
check "label derivations stored as label, missing ones as NULL" "label|label|" \
  "SELECT (SELECT derivation FROM ref.food_nutrient fn JOIN ref.nutrient n USING (nutrient_id) JOIN ref.food_version v USING (food_version_id)
            WHERE v.source_key = '3000001' AND n.code = 'protein')||'|'||
          (SELECT derivation FROM ref.food_nutrient fn JOIN ref.nutrient n USING (nutrient_id) JOIN ref.food_version v USING (food_version_id)
            WHERE v.source_key = '3000001' AND n.code = 'added_sugars')||'|'||
          coalesce((SELECT derivation FROM ref.food_nutrient fn JOIN ref.nutrient n USING (nutrient_id) JOIN ref.food_version v USING (food_version_id)
            WHERE v.source_key = '3000006' AND n.code = 'protein'), '')"
check "added sugars imported" 21.4 "SELECT $(nut 3000001 added_sugars)"
check "label serving became the default portion" "1 serving (0.25 cup)|28.000|true" \
  "SELECT label||'|'||gram_weight||'|'||is_default FROM ref.food_portion
    WHERE food_version_id = (SELECT food_version_id FROM ref.food_version WHERE source_key = '3000001')"
check "volume food: per 100 mL, no gram portion" "per_100ml|LIFEWAY|0" \
  "SELECT nutrient_basis||'|'||brand||'|'||(SELECT count(*) FROM ref.food_portion p WHERE p.food_version_id = v.food_version_id)
     FROM ref.food_version v WHERE source_key = '3000002'"
check "UPC-A stored as GTIN-14" 00036000291452 "SELECT $(bc 3000001)"
check "EAN-13 stored as GTIN-14" 04006381333931 "SELECT $(bc 3000002)"
check "a code missing its check digit stores no barcode" "" "SELECT $(bc 3000006)"
check "identity: GTIN, or fdcId without a valid barcode or when the GTIN is taken in the release" \
  "fdc:3000005;fdc:3000006;fdc:3000007;gtin:00012345678905;gtin:00036000291452;gtin:04006381333931" \
  "SELECT string_agg(identity_key, ';' ORDER BY identity_key) FROM ref.food_identity WHERE source_family = 'FDC_BRANDED'"
check "both listings of one GTIN keep its barcode, both current" "00012345678905|00012345678905|2" \
  "SELECT $(bc 3000004)||'|'||$(bc 3000005)||'|'||(SELECT count(*) FROM ref.food_version WHERE source_key IN ('3000004','3000005') AND is_current)"
check "branded categories in their own scheme" "Cereal" \
  "SELECT g.name FROM ref.food_version v JOIN ref.food_group g ON (g.scheme, g.group_code) = (v.group_scheme, v.group_code)
    WHERE v.source_key = '3000001' AND g.scheme = 'FDC_BRANDED_CATEGORY'"

out_has "import reports the dropped implausible values" "implausible dropped +2 values"
check "impossible energy and sodium dropped, plausible protein kept" "||10|other" \
  "SELECT coalesce($(nut 3000007 energy)::text, '')||'|'||coalesce($(nut 3000007 sodium)::text, '')||'|'||$(nut 3000007 protein)||'|'||energy_method
     FROM ref.food_version WHERE source_key = '3000007'"

echo "-- Branded release 2: new fdcIds, same products"
imp --file "$DATA/branded_r2.json" --release 2027-04
check "granola found by GTIN despite the dropped leading zero" "false|true|480" \
  "SELECT o.is_current||'|'||(o.superseded_by = n.food_version_id)||'|'||$(nut 3100001 energy)
     FROM ref.food_version o, ref.food_version n WHERE o.source_key = '3000001' AND n.source_key = '3100001'"
check "kefir superseded too; brand name preferred over owner" "false|MICHELE'S" \
  "SELECT (SELECT is_current FROM ref.food_version WHERE source_key = '3000002')||'|'||
          (SELECT brand FROM ref.food_version WHERE source_key = '3100001')"
check "old and new versions both answer the barcode" 2 \
  "SELECT count(*) FROM ref.food_barcode WHERE gtin = '00036000291452'"
check "products absent from release 2 stay current" 3 \
  "SELECT count(*) FROM ref.food_version WHERE source_key IN ('3000004','3000005','3000006') AND is_current"
check "exactly one current version per food, all datasets" 0 \
  "SELECT count(*) FROM (SELECT food_id FROM ref.food_version WHERE is_current GROUP BY food_id HAVING count(*) > 1) x"

echo "ALL $pass FDC IMPORTER CHECKS PASSED"
