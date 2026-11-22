package targets

import (
	"strings"
	"testing"
)

// Tests for design 0002: value-type roles, trimester groups, opt-in
// guidelines. Values marked "synthetic" exercise the mechanism and are not
// any authority's real numbers.

func multiCatalog(t *testing.T) *Catalog {
	t.Helper()
	c := resolverCatalog(t)
	c.Nutrients = append(c.Nutrients, Nutrient{100, "sat_fat", "g"}, Nutrient{9, "alcohol", "g"})
	if err := c.Index(); err != nil {
		t.Fatal(err)
	}
	c.Roles = append(c.Roles,
		ValueTypeRole{"EFSA", "PRI", "recommended"}, ValueTypeRole{"EFSA", "UL", "upper_limit"},
		ValueTypeRole{"US_DGA", "DG", "target"}, ValueTypeRole{"US_DGA", "UL", "upper_limit"})
	// EFSA-style trimester groups (synthetic protein PRIs).
	for i, st := range []string{"trimester_1", "trimester_2", "trimester_3"} {
		code := "EFSA/P/" + st
		c.LifeStages = append(c.LifeStages, LifeStage{code, "EFSA", "female", 216, nil, "pregnant", st})
		c.Values = append(c.Values, ReferenceValue{"EFSA", "smoke", code, "protein", "PRI", BasisPerDay, f(float64(60 + 10*i)), nil, "g", "total_intake"})
	}
	// DGA-style guideline groups and values.
	c.LifeStages = append(c.LifeStages,
		LifeStage{"US_DGA/adults", "US_DGA", "any", 228, nil, "none", ""},
		LifeStage{"US_DGA/pregnancy", "US_DGA", "female", 0, nil, "pregnant", ""})
	dg := func(ls, n, basis string, lo, hi *float64, unit string) ReferenceValue {
		return ReferenceValue{"US_DGA", "2025-2030", ls, n, "DG", basis, lo, hi, unit, "total_intake"}
	}
	c.Values = append(c.Values,
		dg("US_DGA/adults", "sat_fat", BasisPctEnergy, nil, f(10), "%"),
		dg("US_DGA/pregnancy", "alcohol", BasisPerDay, nil, f(0), "g"),
		// A guideline can't set upper limits; this one must be ignored.
		ReferenceValue{"US_DGA", "2025-2030", "US_DGA/adults", "vit_c", "UL", BasisPerDay, nil, f(1), "mg", "total_intake"},
	)
	return c
}

var dga = []Guideline{{"US_DGA", "2025-2030"}}

func TestTrimesterFromDueDate(t *testing.T) {
	cat := multiCatalog(t)
	cases := map[string]string{ // due date -> group, on 2026-11-22
		"2027-06-01": "EFSA/P/trimester_1", // 191 days to go: 89 days gestation
		"2027-03-01": "EFSA/P/trimester_2", // 99 days to go: 181 days
		"2026-12-15": "EFSA/P/trimester_3", // 23 days to go: 257 days
		"2026-11-01": "EFSA/P/trimester_3", // past due: still third
	}
	for due, want := range cases {
		in := Inputs{Date: "2026-11-22", Authority: "EFSA", DRIEdition: "smoke",
			Person: Person{BirthDate: "1992-03-01", ReferenceSex: "female", PhysiologicalState: "pregnant", DueDate: due}}
		res, err := Resolve(in, cat)
		if err != nil {
			t.Fatal(err)
		}
		if res.Inputs.LifeStage != want {
			t.Errorf("due %s: group %q, want %q", due, res.Inputs.LifeStage, want)
		}
	}
}

func TestTrimesterGroupsNeedADueDate(t *testing.T) {
	in := Inputs{Date: "2026-11-22", Authority: "EFSA", DRIEdition: "smoke",
		Person: Person{BirthDate: "1992-03-01", ReferenceSex: "female", PhysiologicalState: "pregnant"}}
	res, err := Resolve(in, multiCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, w := range res.Warnings {
		found = found || (w.Code == WarnNoLifeStageGroup && w.Detail["missing_due_date"] == true)
	}
	if res.Inputs.LifeStage != "" || !found {
		t.Fatalf("want no_life_stage_group with missing_due_date, got %+v", res.Warnings)
	}
}

// NASEM has one pregnancy group per age band: a due date changes nothing.
func TestDueDateFallsBackToUnstagedGroup(t *testing.T) {
	in := Inputs{Date: "2026-11-22", Person: Person{BirthDate: "1990-01-01", ReferenceSex: "female",
		PhysiologicalState: "pregnant", DueDate: "2027-03-01"}}
	res, err := Resolve(in, multiCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	if res.Inputs.LifeStage != "NASEM_DRI/P/31-50y" {
		t.Fatalf("group %q", res.Inputs.LifeStage)
	}
}

func TestGuidelineIsOptIn(t *testing.T) {
	cat := multiCatalog(t)
	in := man40()
	res, err := Resolve(in, cat)
	if err != nil {
		t.Fatal(err)
	}
	if target(res, "sat_fat") != nil || res.Inputs.Guidelines != nil {
		t.Fatal("no guideline opted in, but DGA values applied")
	}
	in.Guidelines = dga
	res, err = Resolve(in, cat)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, res, "sat_fat", absent, 0.10*3211/9, SourceAuthority) // <= 10% of 3211 kcal = 35.68 g
	if g := res.Inputs.Guidelines; len(g) != 1 || g[0] != (GuidelineRef{"US_DGA", "2025-2030", "US_DGA/adults"}) {
		t.Errorf("guideline provenance = %+v", g)
	}
	if ul := target(res, "vit_c").UpperLimit; ul == nil || *ul != 2000 {
		t.Errorf("a guideline must not set upper limits: vit_c UL = %v", ul)
	}
}

func TestGuidelineChangesTheHash(t *testing.T) {
	cat := multiCatalog(t)
	in := man40()
	a, _ := Resolve(in, cat)
	in.Guidelines = dga
	b, _ := Resolve(in, cat)
	if a.InputsHash == b.InputsHash {
		t.Fatal("opting into a guideline must change the inputs hash")
	}
}

func TestGuidelineForPregnancy(t *testing.T) {
	in := Inputs{Date: "2026-11-22", Guidelines: dga, Person: Person{BirthDate: "1990-01-01", ReferenceSex: "female",
		PhysiologicalState: "pregnant", DueDate: "2027-03-01"}}
	res, err := Resolve(in, multiCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	expect(t, res, "alcohol", absent, 0, SourceAuthority)
	expect(t, res, "protein", 71, absent, SourceAuthority) // NASEM still primary
}

// Across the primary authority and a guideline, the highest floor wins
// (0001 D2, design 0002 A5). Synthetic 1.2 g/kg guideline floor.
func TestGuidelineFloorCombinesWithAuthority(t *testing.T) {
	cat := multiCatalog(t)
	cat.Values = append(cat.Values, ReferenceValue{"US_DGA", "2025-2030", "US_DGA/adults", "protein", "DG", BasisPerKg, f(1.2), nil, "g", "total_intake"})
	in := man40()
	in.Guidelines = dga
	res, err := Resolve(in, cat)
	if err != nil {
		t.Fatal(err)
	}
	if got := target(res, "protein").Low; got == nil || *got != 126 { // max(0.8, 1.2) g/kg * 105 kg
		t.Fatalf("protein low = %v, want 126", got)
	}
}

func TestUnknownValueTypeIsIgnoredWithAWarning(t *testing.T) {
	cat := multiCatalog(t)
	cat.Values = append(cat.Values, ReferenceValue{"NASEM_DRI", "consolidated-2019", "NASEM_DRI/M/31-50y", "vit_c", "XYZ", BasisPerDay, f(5000), nil, "mg", "total_intake"})
	res, err := Resolve(man40(), cat)
	if err != nil {
		t.Fatal(err)
	}
	if !hasWarning(res, WarnUnknownValueType, "") {
		t.Error("want unknown_value_type")
	}
	expect(t, res, "vit_c", 90, absent, SourceAuthority)
}

func TestMissingRolesIsAnError(t *testing.T) {
	cat := multiCatalog(t)
	cat.Roles = nil
	_, err := Resolve(man40(), cat)
	if err == nil || !strings.Contains(err.Error(), "no value-type roles") {
		t.Fatalf("want a missing-roles error, got %v", err)
	}
}
