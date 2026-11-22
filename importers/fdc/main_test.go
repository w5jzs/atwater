package main

import "testing"

func TestResolveRelease(t *testing.T) {
	const fnd = "/data/FoodData_Central_foundation_food_json_2026-10-29.zip"
	const sr = "FoodData_Central_sr_legacy_food_json_2018-04.zip"
	cases := []struct {
		name, file, release string
		force               bool
		want                string
		wantErr             bool
	}{
		{"foundation date from name", fnd, "", false, "2026-10-29", false},
		{"SR Legacy year-month from name", sr, "", false, "2018-04", false},
		{"unzipped json also dated", "FoodData_Central_foundation_food_json_2025-12-18.json", "", false, "2025-12-18", false},
		{"explicit release matching name", fnd, "2026-10-29", false, "2026-10-29", false},
		{"explicit release contradicting name refused", fnd, "2026-10", false, "", true},
		{"wrong dataset's date refused", sr, "2026-10", false, "", true},
		{"contradiction allowed with --force-release", fnd, "2026-10", true, "2026-10", false},
		{"undated name uses --release", "foundation_r1.json", "2025-04", false, "2025-04", false},
		{"undated name, no --release: empty", "foundation_r1.json", "", false, "", false},
		{"renamed file is undated", "foundation-oct.zip", "", false, "", false},
	}
	for _, c := range cases {
		got, _, err := resolveRelease(c.file, c.release, c.force)
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("%s: resolveRelease(%q, %q, %v) = %q, %v; want %q, err=%v",
				c.name, c.file, c.release, c.force, got, err, c.want, c.wantErr)
		}
	}
}
