package targets

import (
	"math"
	"testing"
)

func ip(v int) *int { return &v }

// resolverCatalog: real NASEM values (catalog seeds 0001-0004) for the
// groups the tests use, and the NASEM 2023 EER equations for men 19+.
func resolverCatalog(t *testing.T) *Catalog {
	t.Helper()
	c := testCatalog(t)
	c.LifeStages = []LifeStage{
		{"NASEM_DRI/M/31-50y", "NASEM_DRI", "male", 372, ip(612), "none"},
		{"NASEM_DRI/M/19+y", "NASEM_DRI", "male", 228, nil, "none"},
		{"NASEM_DRI/F/19+y", "NASEM_DRI", "female", 228, nil, "none"},
		{"NASEM_DRI/P/31-50y", "NASEM_DRI", "female", 372, ip(612), "pregnant"},
		{"NASEM_DRI/I/0-6mo", "NASEM_DRI", "any", 0, ip(6), "none"},
	}
	v := func(ls, n, vt, basis string, lo, hi *float64, unit, applies string) ReferenceValue {
		return ReferenceValue{"NASEM_DRI", "consolidated-2019", ls, n, vt, basis, lo, hi, unit, applies}
	}
	m := "NASEM_DRI/M/31-50y"
	p := "NASEM_DRI/P/31-50y"
	c.Values = []ReferenceValue{
		v(m, "protein", "RDA", BasisPerKg, f(0.8), nil, "g", "total_intake"),
		v(m, "protein", "RDA", BasisPerDay, f(56), nil, "g", "total_intake"),
		v(m, "protein", "AMDR", BasisPctEnergy, f(10), f(35), "%", "total_intake"),
		v(m, "fat", "AMDR", BasisPctEnergy, f(20), f(35), "%", "total_intake"),
		v(m, "carbohydrate", "RDA", BasisPerDay, f(130), nil, "g", "total_intake"),
		v(m, "carbohydrate", "AMDR", BasisPctEnergy, f(45), f(65), "%", "total_intake"),
		v(m, "fiber", "AI", BasisPerDay, f(38), nil, "g", "total_intake"),
		v(m, "vit_c", "RDA", BasisPerDay, f(90), nil, "mg", "total_intake"),
		v(m, "vit_c", "UL", BasisPerDay, nil, f(2000), "mg", "total_intake"),
		v(m, "vit_d", "RDA", BasisPerDay, f(15), nil, "ug", "total_intake"),
		v(m, "vit_d", "UL", BasisPerDay, nil, f(100), "ug", "total_intake"),
		v(m, "sodium", "AI", BasisPerDay, f(1500), nil, "mg", "total_intake"),
		v(m, "sodium", "CDRR", BasisPerDay, nil, f(2300), "mg", "total_intake"),
		v(p, "protein", "RDA", BasisPerDay, f(71), nil, "g", "total_intake"),
		v(p, "vit_c", "RDA", BasisPerDay, f(85), nil, "mg", "total_intake"),
		v("NASEM_DRI/I/0-6mo", "vit_c", "AI", BasisPerDay, f(40), nil, "mg", "total_intake"),
	}
	c.EnergyEquations = []EnergyEquation{
		{"NASEM_DRI", "2023-energy", "NASEM_DRI/M/19+y", "inactive", 753.07, -10.83, 6.50, 14.10, 0},
		{"NASEM_DRI", "2023-energy", "NASEM_DRI/M/19+y", "low_active", 581.47, -10.83, 8.30, 14.94, 0},
	}
	return c
}

// man40 is the design doc's worked-example person: 40 y, 180 cm, low active,
// weighing 105 kg every day of the past week.
func man40() Inputs {
	in := Inputs{Date: "2026-11-22",
		Person: Person{BirthDate: "1986-06-15", ReferenceSex: "male", HeightCM: f(180), ActivityLevel: "low_active"}}
	for _, d := range []string{"2026-11-16", "2026-11-18", "2026-11-20", "2026-11-22"} {
		in.BodyMass = append(in.BodyMass, Reading{d, 105})
	}
	return in
}

func d1Plan(t *testing.T, adjust int) *Plan {
	r, err := ParseRules([]byte(d1Example), testCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	return &Plan{VersionID: "plan-d1", RulesSchemaVersion: 1, Rules: r, EnergyAdjustKcal: adjust}
}

func resolve(t *testing.T, in Inputs) *Result {
	t.Helper()
	res, err := Resolve(in, resolverCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func target(res *Result, n string) *Target {
	for i := range res.Targets {
		if res.Targets[i].Nutrient == n {
			return &res.Targets[i]
		}
	}
	return nil
}

func hasWarning(res *Result, code, nutrient string) bool {
	for _, w := range res.Warnings {
		if w.Code == code && w.Nutrient == nutrient {
			return true
		}
	}
	return false
}

const absent = -1.0

func expect(t *testing.T, res *Result, n string, low, high float64, source string) {
	t.Helper()
	tg := target(res, n)
	if tg == nil {
		t.Errorf("%s: no target", n)
		return
	}
	near := func(name string, got *float64, want float64) {
		if want == absent {
			if got != nil {
				t.Errorf("%s %s = %v, want none", n, name, *got)
			}
			return
		}
		if got == nil || math.Abs(*got-want) > 1e-6 {
			t.Errorf("%s %s = %v, want %v", n, name, got, want)
		}
	}
	near("low", tg.Low, low)
	near("high", tg.High, high)
	if source != "" && tg.Source != source {
		t.Errorf("%s source = %s, want %s", n, tg.Source, source)
	}
}

// The design doc's worked example, with the real NASEM 2023 equation instead
// of the doc's illustrative 2,900 kcal. Expected values computed by hand:
//
//	EER  = 581.47 - 10.83*40 + 8.30*180 + 14.94*105 = 3210.97 kcal
//	energy = round(3210.97 - 500) = 2711 kcal
//	protein >= 1.6 g/kg * 81 kg (BMI 25 at 180 cm) = 129.6 g        (518.4 kcal)
//	fat 25-35% of 2711 = 677.75-948.85 kcal = 75.305556-105.427778 g
//	carbohydrate <= (2711 - 518.4 - 677.75) / 4 = 378.7125 g; no low, because
//	  protein has no high
//	fiber >= 14 * 2.711 = 37.954 g;  sodium <= 2300 mg (plan)
func TestWorkedExample(t *testing.T) {
	in := man40()
	in.Plan = d1Plan(t, -500)
	res := resolve(t, in)

	expect(t, res, "energy", 2711, 2711, SourcePlan)
	if e := res.Inputs.Energy; e.EstimateKcal == nil || *e.EstimateKcal != 3210.97 || *e.AgeYears != 40 {
		t.Errorf("energy inputs = %+v", e)
	}
	expect(t, res, "protein", 129.6, absent, SourcePlan)
	expect(t, res, "fat", 677.75/9, 948.85/9, SourcePlan)
	expect(t, res, "carbohydrate", absent, 378.7125, SourcePlanRemainder)
	expect(t, res, "fiber", 37.954, absent, SourcePlan)
	expect(t, res, "sodium", absent, 2300, SourcePlan)
	expect(t, res, "vit_c", 90, absent, SourceAuthority) // inherited
	if ul := target(res, "vit_c").UpperLimit; ul == nil || *ul != 2000 {
		t.Errorf("vit_c upper limit = %v", ul)
	}
	if bm := res.Inputs.BodyMass; bm.MeasuredKG != 105 || *bm.ReferenceKG != 81 || bm.Basis != "reference_bmi" {
		t.Errorf("body mass inputs = %+v", bm)
	}
	// 14 g/1000 kcal at 2711 kcal is 37.954 g, just under the 38 g AI: the
	// plan's fiber rule falls short at this energy budget, and says so.
	if res.Inputs.LifeStage != "NASEM_DRI/M/31-50y" || len(res.Warnings) != 1 || !hasWarning(res, WarnBelowRecommended, "fiber") {
		t.Errorf("life stage %s, warnings %+v", res.Inputs.LifeStage, res.Warnings)
	}
}

// No plan: authority values only, energy = EER. Within the authority layer
// the highest low and lowest high win (carbohydrate RDA 130 g vs AMDR 45%).
func TestAuthorityOnly(t *testing.T) {
	res := resolve(t, man40())
	e := 3211.0 // round(3210.97)
	expect(t, res, "energy", e, e, SourceAuthority)
	expect(t, res, "carbohydrate", 0.45*e/4, 0.65*e/4, SourceAuthority)
	expect(t, res, "protein", 84, 0.35*e/4, SourceAuthority) // max(0.8 g/kg * 105 kg = 84 g, 10% E = 80.3 g)
	expect(t, res, "sodium", 1500, 2300, SourceAuthority)
	expect(t, res, "fiber", 38, absent, SourceAuthority)
}

func TestProteinPrefersPerKgWhenWeightKnown(t *testing.T) {
	in := man40()
	in.BodyMass = []Reading{{"2026-11-22", 150}} // 0.8*150 = 120 g > 10% of energy
	res := resolve(t, in)
	if got := target(res, "protein").Low; got == nil || *got != 120 {
		t.Errorf("protein low = %v, want 120 (0.8 g/kg * 150 kg)", got)
	}
	in.BodyMass = nil // no weight: per-day RDA (56 g); no energy either
	res = resolve(t, in)
	expect(t, res, "protein", 56, absent, SourceAuthority)
}

func TestMissingActivityLevel(t *testing.T) {
	in := man40()
	in.Person.ActivityLevel = ""
	in.Plan = d1Plan(t, -500)
	res := resolve(t, in)
	if target(res, "energy") != nil || !hasWarning(res, WarnUnresolvedNutrient, "energy") {
		t.Fatalf("energy should be unresolved: %+v", res.Warnings)
	}
	for _, n := range []string{"fat", "fiber", "carbohydrate"} { // need energy
		if target(res, n) != nil || !hasWarning(res, WarnUnresolvedNutrient, n) {
			t.Errorf("%s should be unresolved", n)
		}
	}
	expect(t, res, "protein", 129.6, absent, SourcePlan) // per-kg still resolves
}

func TestBodyMassTrendAndStaleness(t *testing.T) {
	in := man40()
	in.BodyMass = []Reading{{"2026-11-22", 104.6}, {"2026-11-21", 105.2}, {"2026-11-10", 120}}
	res := resolve(t, in)
	if res.Inputs.BodyMass.MeasuredKG != 105 { // mean 104.9 -> 105.0; the 12-day-old reading is outside the window
		t.Errorf("trend = %v", res.Inputs.BodyMass.MeasuredKG)
	}
	in.BodyMass = []Reading{{"2026-10-23", 104.3}} // 30 days old
	res = resolve(t, in)
	if !hasWarning(res, WarnStaleBodyMass, "") || res.Inputs.BodyMass.MeasuredKG != 104.5 || !res.Inputs.BodyMass.Stale {
		t.Errorf("stale reading not used: %+v %+v", res.Inputs.BodyMass, res.Warnings)
	}
	in.BodyMass = []Reading{{"2026-08-01", 104}, {"2026-11-23", 99}} // too old, and tomorrow's
	res = resolve(t, in)
	if res.Inputs.BodyMass != nil || target(res, "energy") != nil {
		t.Errorf("no usable reading, but got %+v", res.Inputs.BodyMass)
	}
}

func TestInfantUsesAnySexGroup(t *testing.T) {
	in := Inputs{Date: "2026-11-22", Person: Person{BirthDate: "2026-08-01", ReferenceSex: "female"}}
	res := resolve(t, in)
	if res.Inputs.LifeStage != "NASEM_DRI/I/0-6mo" {
		t.Fatalf("life stage = %q", res.Inputs.LifeStage)
	}
	expect(t, res, "vit_c", 40, absent, SourceAuthority)
}

func TestPregnancy(t *testing.T) {
	in := Inputs{Date: "2026-11-22", Person: Person{BirthDate: "1990-01-01", ReferenceSex: "female",
		HeightCM: f(165), ActivityLevel: "active", PhysiologicalState: "pregnant"},
		BodyMass: []Reading{{"2026-11-22", 70}}}
	res := resolve(t, in)
	if res.Inputs.LifeStage != "NASEM_DRI/P/31-50y" {
		t.Fatalf("life stage = %q", res.Inputs.LifeStage)
	}
	expect(t, res, "protein", 71, absent, SourceAuthority)
	// No pregnancy EER equations are loaded, so no energy target.
	if target(res, "energy") != nil || !hasWarning(res, WarnUnresolvedNutrient, "energy") {
		t.Errorf("pregnancy energy should be unresolved")
	}
}

func TestNoLifeStageGroup(t *testing.T) {
	in := man40()
	in.Person.BirthDate = ""
	res := resolve(t, in)
	if !hasWarning(res, WarnNoLifeStageGroup, "") || target(res, "vit_c") != nil {
		t.Fatalf("want no_life_stage_group and no authority targets: %+v", res.Warnings)
	}
}

func TestOverrides(t *testing.T) {
	in := man40()
	in.Plan = d1Plan(t, -500)
	in.Overrides = []Override{
		// user and clinician both set vitamin D; clinician wins, and is above the UL
		{ID: "o1", Version: 1, NutrientID: 202, Basis: BasisPerDay, Low: f(50), SetBy: "user", ValidFrom: "2026-01-01"},
		{ID: "o2", Version: 3, NutrientID: 202, Basis: BasisPerDay, Low: f(125), SetBy: "clinician", ValidFrom: "2026-01-01"},
		// user lowers vitamin C below the RDA
		{ID: "o3", Version: 1, NutrientID: 201, Basis: BasisPerDay, Low: f(60), SetBy: "user", ValidFrom: "2026-11-01"},
		// expired and not-yet-valid overrides are ignored
		{ID: "o4", Version: 1, NutrientID: 305, Basis: BasisPerDay, High: f(1000), SetBy: "user", ValidFrom: "2026-01-01", ValidTo: "2026-11-22"},
		{ID: "o5", Version: 1, NutrientID: 305, Basis: BasisPerDay, High: f(1000), SetBy: "user", ValidFrom: "2026-11-23"},
	}
	res := resolve(t, in)
	expect(t, res, "vit_d", 125, absent, SourceClinician)
	if !hasWarning(res, WarnExceedsUpperLimit, "vit_d") {
		t.Error("want exceeds_upper_limit for vit_d")
	}
	expect(t, res, "vit_c", 60, absent, SourceUser)
	if !hasWarning(res, WarnBelowRecommended, "vit_c") {
		t.Error("want below_recommended for vit_c")
	}
	expect(t, res, "sodium", absent, 2300, SourcePlan) // o4/o5 not in force
	if got := res.Inputs.Overrides; len(got) != 3 || got[1] != (OverrideRef{"o2", 3}) {
		t.Errorf("override provenance = %+v", got)
	}
}

func TestEnergyFarFromEstimateAndOverride(t *testing.T) {
	in := man40()
	in.Plan = d1Plan(t, 0)
	in.Plan.Rules.Energy = &EnergyRule{Method: "fixed", Kcal: f(1200)}
	res := resolve(t, in)
	expect(t, res, "energy", 1200, 1200, SourcePlan)
	if !hasWarning(res, WarnEnergyFarFromEstimate, "energy") {
		t.Error("1200 kcal vs a 3211 kcal estimate should warn")
	}
	in.Overrides = []Override{{ID: "e1", Version: 1, NutrientID: 1, Basis: BasisPerDay, Low: f(3000), SetBy: "clinician", ValidFrom: "2026-01-01"}}
	res = resolve(t, in)
	expect(t, res, "energy", 3000, 3000, SourceClinician)
	if hasWarning(res, WarnEnergyFarFromEstimate, "energy") {
		t.Error("3000 kcal is within 25% of 3211 kcal")
	}
	expect(t, res, "fat", 0.25*3000/9, 0.35*3000/9, SourcePlan) // converted against the overridden energy
}

func TestRemainderInfeasible(t *testing.T) {
	in := man40()
	in.Plan = d1Plan(t, 0)
	in.Plan.Rules.Energy = &EnergyRule{Method: "fixed", Kcal: f(900)}
	in.Plan.Rules.Nutrients[0].Low = f(3.0) // 3 g/kg * 81 kg = 243 g protein = 972 kcal alone
	res := resolve(t, in)
	if target(res, "carbohydrate") != nil || !hasWarning(res, WarnRemainderInfeasible, "carbohydrate") {
		t.Fatalf("want an infeasible remainder: %+v", res.Warnings)
	}
}

func TestInheritAuthorityFalse(t *testing.T) {
	in := man40()
	in.Plan = d1Plan(t, 0)
	no := false
	in.Plan.Rules.InheritAuthority = &no
	res := resolve(t, in)
	tg := target(res, "vit_c")
	if tg == nil || tg.Low != nil || tg.UpperLimit == nil {
		t.Fatalf("vit_c should keep only its upper limit, got %+v", tg)
	}
}

func TestBadInputs(t *testing.T) {
	cat := resolverCatalog(t)
	for name, in := range map[string]Inputs{
		"bad date":         {Date: "22/11/2026"},
		"born after date":  {Date: "2026-11-22", Person: Person{BirthDate: "2027-01-01"}},
		"unknown nutrient": {Date: "2026-11-22", Overrides: []Override{{ID: "x", NutrientID: 999, SetBy: "user", ValidFrom: "2026-01-01"}}},
		"bad set_by":       {Date: "2026-11-22", Overrides: []Override{{ID: "x", NutrientID: 201, SetBy: "admin", ValidFrom: "2026-01-01"}}},
	} {
		if _, err := Resolve(in, cat); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}
