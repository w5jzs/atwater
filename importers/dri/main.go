// dri-seedgen turns the raw NASEM DRI summary-table transcriptions
// (catalog/data/nasem-dri/*.csv) into a catalog seed file.
//
//	go run . -data ../../catalog/data/nasem-dri -out ../../catalog/seed/0004_ref_dri_nasem_consolidated_2019.sql
//	go run . -data ... -out ... -check   # fail if the committed seed is stale
//
// Validation happens twice:
//   - here, before anything is written: every life-stage label and column is
//     known (mapped or skipped with a reason), every value parses, no key
//     repeats, and no RDA/AI exceeds a total-intake UL or the sodium CDRR;
//   - in the generated SQL, against the live catalog: every nutrient code
//     exists, units match each nutrient's canonical unit, and any row or
//     life-stage group that already exists (the hand-written 0001/0002
//     seeds) must match exactly, or the whole file rolls back.
package main

import (
	"bytes"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type value struct {
	LifeStage string // code
	Nutrient  string // code
	ValueType string
	Basis     string
	Low, High *float64
	Unit      string
	AppliesTo string
	Note      string
	Source    string
	Table     string
}

func (v value) key() string {
	return v.LifeStage + "|" + v.Nutrient + "|" + v.ValueType + "|" + v.Basis
}

type result struct {
	Values  []value
	Stages  []lifeStage
	Skipped map[string]string // "table: column" -> reason
	Empty   int               // ND / UNREADABLE cells in mapped columns
}

var (
	cellRe  = regexp.MustCompile(`^([0-9][0-9,]*(?:\.[0-9]+)?)(\*?)([a-z]*)$`)
	rangeRe = regexp.MustCompile(`^([0-9.]+)–([0-9.]+)$`)
)

func parseNumber(s string) (float64, error) {
	return strconv.ParseFloat(strings.ReplaceAll(s, ",", ""), 64)
}

func isEmpty(cell string) bool {
	return strings.HasPrefix(cell, "ND") || cell == "UNREADABLE"
}

func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }

func build(dataDir string) (*result, error) {
	res := &result{Skipped: map[string]string{}}
	seen := map[string]value{}
	usedStages := map[string]lifeStage{}
	var errs []error

	for _, t := range tables {
		f, err := os.Open(filepath.Join(dataDir, t.File))
		if err != nil {
			return nil, err
		}
		rows, err := csv.NewReader(f).ReadAll()
		f.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", t.File, err)
		}
		header := rows[0]
		for _, h := range header[1:] {
			c, ok := t.Cols[h]
			if !ok {
				errs = append(errs, fmt.Errorf("%s: unknown column %q (map it or skip it in mapping.go)", t.File, h))
			} else if c.Skip != "" {
				res.Skipped[t.File+": "+h] = c.Skip
			}
		}
		for _, row := range rows[1:] {
			label := row[0]
			var stageLabels []string
			if t.Groups != nil {
				g, ok := t.Groups[label]
				if !ok {
					errs = append(errs, fmt.Errorf("%s: unknown population group %q", t.File, label))
					continue
				}
				stageLabels = g
			} else {
				if _, ok := lifeStages[label]; !ok {
					errs = append(errs, fmt.Errorf("%s: unknown life stage %q", t.File, label))
					continue
				}
				stageLabels = []string{label}
			}
			source := t.Source
			for i, h := range header {
				if h == "source_table" && strings.Contains(row[i], "S-2") {
					source = s2URL
				}
			}
			for i, h := range header[1:] {
				c, ok := t.Cols[h]
				if !ok || c.Skip != "" {
					continue
				}
				cell := strings.TrimSpace(row[i+1])
				if isEmpty(cell) {
					res.Empty++
					continue
				}
				v := value{Nutrient: c.Nutrient, Unit: c.Unit, AppliesTo: c.AppliesTo, Note: c.Note, Source: source, Table: t.File}
				switch t.Kind {
				case "amdr":
					m := rangeRe.FindStringSubmatch(cell)
					if m == nil {
						errs = append(errs, fmt.Errorf("%s: %s / %s: unparseable range %q", t.File, label, h, cell))
						continue
					}
					lo, _ := parseNumber(m[1])
					hi, _ := parseNumber(m[2])
					v.ValueType, v.Basis, v.Low, v.High = "AMDR", "pct_energy", &lo, &hi
				default:
					m := cellRe.FindStringSubmatch(cell)
					if m == nil {
						errs = append(errs, fmt.Errorf("%s: %s / %s: unparseable value %q", t.File, label, h, cell))
						continue
					}
					n, err := parseNumber(m[1])
					if err != nil || n <= 0 {
						errs = append(errs, fmt.Errorf("%s: %s / %s: bad amount %q", t.File, label, h, cell))
						continue
					}
					n = round6(n * c.Factor)
					v.Basis = "per_day"
					switch t.Kind {
					case "rda_ai":
						v.ValueType = "RDA"
						if m[2] == "*" {
							v.ValueType = "AI"
						}
						v.Low = &n
					case "ul":
						if m[2] == "*" {
							errs = append(errs, fmt.Errorf("%s: %s / %s: UL marked as AI %q", t.File, label, h, cell))
							continue
						}
						v.ValueType, v.High = "UL", &n
					case "cdrr":
						v.ValueType, v.High = "CDRR", &n
					}
				}
				for _, sl := range stageLabels {
					st := lifeStages[sl]
					usedStages[st.Code] = st
					vv := v
					vv.LifeStage = st.Code
					if prev, dup := seen[vv.key()]; dup {
						errs = append(errs, fmt.Errorf("duplicate %s (from %s and %s)", vv.key(), prev.Table, vv.Table))
						continue
					}
					seen[vv.key()] = vv
				}
			}
		}
	}

	// Cross-table rules: a target must not exceed a total-intake UL or the
	// sodium CDRR for the same group and nutrient (same canonical unit).
	for _, v := range seen {
		if v.ValueType != "RDA" && v.ValueType != "AI" {
			continue
		}
		for _, capType := range []string{"UL", "CDRR"} {
			c, ok := seen[v.LifeStage+"|"+v.Nutrient+"|"+capType+"|per_day"]
			if !ok || c.AppliesTo != "total_intake" || c.Unit != v.Unit {
				continue
			}
			if *v.Low > *c.High {
				errs = append(errs, fmt.Errorf("%s %s: %s %g %s exceeds %s %g", v.LifeStage, v.Nutrient, v.ValueType, *v.Low, v.Unit, capType, *c.High))
			}
		}
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}

	for _, v := range seen {
		res.Values = append(res.Values, v)
	}
	sort.Slice(res.Values, func(i, j int) bool { return res.Values[i].key() < res.Values[j].key() })
	for _, st := range usedStages {
		res.Stages = append(res.Stages, st)
	}
	sort.Slice(res.Stages, func(i, j int) bool { return res.Stages[i].Code < res.Stages[j].Code })
	return res, nil
}

func lit(s string) string {
	if s == "" {
		return "NULL"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func num(p *float64) string {
	if p == nil {
		return "NULL"
	}
	return strconv.FormatFloat(*p, 'f', -1, 64)
}

func render(res *result) []byte {
	var b bytes.Buffer
	w := func(format string, a ...any) { fmt.Fprintf(&b, format, a...) }

	w("-- =====================================================================\n")
	w("-- Atwater seed · 0004 · NASEM DRIs, all life-stage groups\n")
	w("--\n")
	w("-- GENERATED by importers/dri from catalog/data/nasem-dri/*.csv.\n")
	w("-- Do not edit by hand: change the CSVs or mapping.go and regenerate.\n")
	w("-- Applied seed files are checksum-tracked, so a regenerated file needs\n")
	w("-- a new seed number rather than replacing this one once applied.\n")
	w("--\n")
	w("-- Source: NASEM 2019, Dietary Reference Intakes for Sodium and\n")
	w("-- Potassium, Appendix J (consolidated DRI summary tables); see\n")
	w("-- catalog/data/nasem-dri/SOURCES.md.\n")
	w("--\n")
	w("-- %d reference values for %d life-stage groups. Rows the 0001/0002 seeds\n", len(res.Values), len(res.Stages))
	w("-- already hold must match exactly, or this file raises and rolls back.\n")
	w("--\n")
	w("-- Columns not loaded:\n")
	var sk []string
	for k := range res.Skipped {
		sk = append(sk, k)
	}
	sort.Strings(sk)
	for _, k := range sk {
		w("--   %s: %s\n", k, res.Skipped[k])
	}
	w("-- =====================================================================\n")
	w("BEGIN;\n\n")

	w("CREATE TEMP TABLE dri_stage (life_stage_code text, sex text, age_min_months int, age_max_months int,\n")
	w("                              physiological_state text, label text) ON COMMIT DROP;\n")
	w("INSERT INTO dri_stage VALUES\n")
	for i, st := range res.Stages {
		hi := "NULL"
		if st.MaxMonths > 0 {
			hi = strconv.Itoa(st.MaxMonths)
		}
		sep := ","
		if i == len(res.Stages)-1 {
			sep = ";"
		}
		w("  (%s, %s, %d, %s, %s, %s)%s\n", lit(st.Code), lit(st.Sex), st.MinMonths, hi, lit(st.State), lit(st.Label), sep)
	}

	w(`
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(g.life_stage_code, ', ') INTO bad
    FROM dri_stage s JOIN ref.life_stage_group g USING (life_stage_code)
   WHERE (g.authority_code, g.sex, g.age_min_months, g.age_max_months, g.physiological_state)
         IS DISTINCT FROM ('%s', s.sex, s.age_min_months, s.age_max_months, s.physiological_state);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'existing life-stage groups differ from the generated ones: %%', bad;
  END IF;
END $$;

INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, age_max_months, physiological_state, label)
SELECT s.life_stage_code, '%s', s.sex, s.age_min_months, s.age_max_months, s.physiological_state, s.label
  FROM dri_stage s
 WHERE NOT EXISTS (SELECT 1 FROM ref.life_stage_group g WHERE g.life_stage_code = s.life_stage_code)
 ORDER BY s.life_stage_code;

`, authority, authority)

	w("CREATE TEMP TABLE dri_value (life_stage_code text, nutrient_code text, value_type text, basis text,\n")
	w("                              amount_low numeric, amount_high numeric, unit_code text, applies_to text,\n")
	w("                              note text, source_url text) ON COMMIT DROP;\n")
	w("INSERT INTO dri_value VALUES\n")
	for i, v := range res.Values {
		sep := ","
		if i == len(res.Values)-1 {
			sep = ";"
		}
		w("  (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)%s\n", lit(v.LifeStage), lit(v.Nutrient), lit(v.ValueType), lit(v.Basis),
			num(v.Low), num(v.High), lit(v.Unit), lit(v.AppliesTo), lit(v.Note), lit(v.Source), sep)
	}

	w(`
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(DISTINCT v.nutrient_code, ', ') INTO bad
    FROM dri_value v LEFT JOIN ref.nutrient n ON n.code = v.nutrient_code WHERE n.nutrient_id IS NULL;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'unknown nutrient codes: %%', bad; END IF;

  SELECT string_agg(DISTINCT v.nutrient_code || ' (' || v.unit_code || ' vs ' || n.unit_code || ')', ', ') INTO bad
    FROM dri_value v JOIN ref.nutrient n ON n.code = v.nutrient_code
   WHERE v.unit_code <> CASE WHEN v.basis = 'pct_energy' THEN '%%' ELSE n.unit_code END;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'units differ from the nutrients'' canonical units: %%', bad; END IF;

  SELECT string_agg(r.life_stage_code || ' ' || v.nutrient_code || ' ' || r.value_type || ' ' || r.basis
                    || ': catalog ' || coalesce(r.amount_low::text, '-') || '/' || coalesce(r.amount_high::text, '-')
                    || ' ' || r.unit_code || ' ' || r.applies_to
                    || ', generated ' || coalesce(v.amount_low::text, '-') || '/' || coalesce(v.amount_high::text, '-')
                    || ' ' || v.unit_code || ' ' || v.applies_to, '; ') INTO bad
    FROM dri_value v
    JOIN ref.nutrient n ON n.code = v.nutrient_code
    JOIN ref.nutrient_reference_value r
      ON (r.authority_code, r.edition, r.life_stage_code, r.nutrient_id, r.value_type, r.basis)
       = ('%s', '%s', v.life_stage_code, n.nutrient_id, v.value_type, v.basis)
   WHERE (r.amount_low, r.amount_high, r.unit_code, r.applies_to)
         IS DISTINCT FROM (v.amount_low, v.amount_high, v.unit_code, v.applies_to);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'existing reference values differ from the transcription: %%', bad; END IF;
END $$;

INSERT INTO ref.nutrient_reference_value
  (authority_code, edition, life_stage_code, nutrient_id, value_type, basis,
   amount_low, amount_high, unit_code, applies_to, note, source_url)
SELECT '%s', '%s', v.life_stage_code, n.nutrient_id, v.value_type, v.basis,
       v.amount_low, v.amount_high, v.unit_code, v.applies_to, v.note, v.source_url
  FROM dri_value v JOIN ref.nutrient n ON n.code = v.nutrient_code
 WHERE NOT EXISTS (
   SELECT 1 FROM ref.nutrient_reference_value r
    WHERE (r.authority_code, r.edition, r.life_stage_code, r.nutrient_id, r.value_type, r.basis)
        = ('%s', '%s', v.life_stage_code, n.nutrient_id, v.value_type, v.basis))
 ORDER BY v.life_stage_code, v.nutrient_code, v.value_type, v.basis;

COMMIT;
`, authority, edition, authority, edition, authority, edition)
	return b.Bytes()
}

func main() {
	data := flag.String("data", "../../catalog/data/nasem-dri", "directory with the raw DRI CSVs")
	out := flag.String("out", "../../catalog/seed/0004_ref_dri_nasem_consolidated_2019.sql", "seed file to write")
	check := flag.Bool("check", false, "don't write; fail if -out differs from what would be generated")
	flag.Parse()

	res, err := build(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dri-seedgen: validation failed:\n"+err.Error())
		os.Exit(1)
	}
	sql := render(res)
	if *check {
		have, err := os.ReadFile(*out)
		if err != nil || !bytes.Equal(have, sql) {
			fmt.Fprintf(os.Stderr, "dri-seedgen: %s is missing or stale; regenerate it\n", *out)
			os.Exit(1)
		}
		fmt.Printf("%s is up to date (%d values, %d life-stage groups)\n", *out, len(res.Values), len(res.Stages))
		return
	}
	if err := os.WriteFile(*out, sql, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "dri-seedgen:", err)
		os.Exit(1)
	}
	byType := map[string]int{}
	for _, v := range res.Values {
		byType[v.ValueType]++
	}
	fmt.Printf("wrote %s: %d values (%v), %d life-stage groups, %d empty cells (ND), %d columns not loaded\n",
		*out, len(res.Values), byType, len(res.Stages), res.Empty, len(res.Skipped))
}
