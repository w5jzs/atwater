package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const dataDir = "../../catalog/data/nasem-dri"
const seedFile = "../../catalog/seed/0004_ref_dri_nasem_consolidated_2019.sql"

func mustBuild(t *testing.T, dir string) *result {
	t.Helper()
	res, err := build(dir)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	return res
}

func find(res *result, stage, nutrient, vt string) *value {
	for i := range res.Values {
		v := &res.Values[i]
		if v.LifeStage == stage && v.Nutrient == nutrient && v.ValueType == vt {
			return v
		}
	}
	return nil
}

// The committed seed must be exactly what the CSVs and mapping produce.
func TestSeedUpToDate(t *testing.T) {
	have, err := os.ReadFile(seedFile)
	if err != nil {
		t.Fatalf("reading committed seed: %v", err)
	}
	if !bytes.Equal(have, render(mustBuild(t, dataDir))) {
		t.Fatalf("%s is stale: run `go run .` in importers/dri", seedFile)
	}
}

// Spot checks against the printed tables, including unit conversions,
// AI vs RDA, applies_to, and expansion of population groups.
func TestKnownValues(t *testing.T) {
	res := mustBuild(t, dataDir)
	cases := []struct {
		stage, nutrient, vt string
		low, high           float64 // -1 = must be NULL
		applies             string
	}{
		{"NASEM_DRI/M/31-50y", "vit_c", "RDA", 90, -1, "total_intake"},
		{"NASEM_DRI/M/31-50y", "potassium", "AI", 3400, -1, "total_intake"},
		{"NASEM_DRI/I/0-6mo", "manganese", "AI", 0.003, -1, "total_intake"},
		{"NASEM_DRI/F/19-30y", "copper", "RDA", 0.9, -1, "total_intake"},     // 900 μg -> mg
		{"NASEM_DRI/M/19-30y", "copper", "UL", -1, 10, "total_intake"},       // 10,000 μg -> mg
		{"NASEM_DRI/L/19-30y", "phosphorus", "UL", -1, 4000, "total_intake"}, // 4 g -> mg
		{"NASEM_DRI/M/71+y", "choline", "UL", -1, 3500, "total_intake"},      // 3.5 g -> mg
		{"NASEM_DRI/M/31-50y", "magnesium", "UL", -1, 350, "supplements_only"},
		{"NASEM_DRI/F/31-50y", "vit_e", "UL", -1, 1000, "supplements_only"},
		{"NASEM_DRI/P/31-50y", "zinc", "RDA", 11, -1, "total_intake"},       // corrected row
		{"NASEM_DRI/P/31-50y", "potassium", "AI", 2900, -1, "total_intake"}, // corrected row
		{"NASEM_DRI/P/14-18y", "fat", "AMDR", 25, 35, "total_intake"},       // children 4-18 AMDR
		{"NASEM_DRI/L/31-50y", "protein", "AMDR", 10, 35, "total_intake"},   // adult AMDR
		{"NASEM_DRI/F/9-13y", "sodium", "CDRR", -1, 1800, "total_intake"},   // adolescents
		{"NASEM_DRI/P/19-30y", "sodium", "CDRR", -1, 2300, "total_intake"},  // Table S-2
		{"NASEM_DRI/I/0-6mo", "fat", "AI", 31, -1, "total_intake"},
		{"NASEM_DRI/I/7-12mo", "protein", "RDA", 11, -1, "total_intake"},
	}
	for _, c := range cases {
		v := find(res, c.stage, c.nutrient, c.vt)
		if v == nil {
			t.Errorf("%s %s %s: missing", c.stage, c.nutrient, c.vt)
			continue
		}
		check := func(name string, got *float64, want float64) {
			if want < 0 {
				if got != nil {
					t.Errorf("%s %s %s: %s = %v, want NULL", c.stage, c.nutrient, c.vt, name, *got)
				}
				return
			}
			if got == nil || *got != want {
				t.Errorf("%s %s %s: %s = %v, want %v", c.stage, c.nutrient, c.vt, name, got, want)
			}
		}
		check("low", v.Low, c.low)
		check("high", v.High, c.high)
		if v.AppliesTo != c.applies {
			t.Errorf("%s %s %s: applies_to = %s, want %s", c.stage, c.nutrient, c.vt, v.AppliesTo, c.applies)
		}
	}
	// Things that must NOT load.
	for _, nope := range []struct{ stage, nutrient, vt string }{
		{"NASEM_DRI/M/31-50y", "vit_a_rae", "UL"},  // preformed only, catalog is RAE
		{"NASEM_DRI/M/31-50y", "folate_dfe", "UL"}, // folic acid, not DFE
		{"NASEM_DRI/M/31-50y", "fat", "RDA"},       // ND
		{"NASEM_DRI/M/31-50y", "water", "AI"},      // total water != food water
	} {
		if find(res, nope.stage, nope.nutrient, nope.vt) != nil {
			t.Errorf("%s %s %s: loaded but shouldn't be", nope.stage, nope.nutrient, nope.vt)
		}
	}
}

// Validation rejects bad input instead of silently loading or dropping it.
func TestValidationRejects(t *testing.T) {
	cases := map[string]struct{ file, from, to, wantErr string }{
		"unknown column":     {"rda_ai_vitamins.csv", "Biotin (μg/d)", "Biotin (ng/d)", "unknown column"},
		"unknown life stage": {"rda_ai_vitamins.csv", "Males 31–50 y", "Males 31–49 y", "unknown life stage"},
		"garbage value":      {"rda_ai_vitamins.csv", "Males 31–50 y,900,90", "Males 31–50 y,9O0,90", "unparseable value"},
		"RDA above UL":       {"ul_vitamins.csv", "Males 31–50 y,\"3,000\",\"2,000\"", "Males 31–50 y,\"3,000\",80", "exceeds UL"},
		"AI above CDRR":      {"cdrr_sodium.csv", "Adults ≥ 19 y,\"2,300\"", "Adults ≥ 19 y,\"1,000\"", "exceeds CDRR"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			entries, _ := os.ReadDir(dataDir)
			for _, e := range entries {
				b, _ := os.ReadFile(filepath.Join(dataDir, e.Name()))
				if e.Name() == c.file {
					if !bytes.Contains(b, []byte(c.from)) {
						t.Fatalf("fixture text %q not found in %s", c.from, c.file)
					}
					b = bytes.Replace(b, []byte(c.from), []byte(c.to), 1)
				}
				os.WriteFile(filepath.Join(dir, e.Name()), b, 0o644)
			}
			_, err := build(dir)
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Fatalf("want error containing %q, got %v", c.wantErr, err)
			}
		})
	}
}
