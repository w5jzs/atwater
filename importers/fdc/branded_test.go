package main

import (
	"strconv"
	"testing"
)

func TestNormalizeGTIN(t *testing.T) {
	cases := map[string]string{ // raw -> GTIN-14, "" = rejected
		"036000291452":    "00036000291452", // UPC-A
		"36000291452":     "00036000291452", // leading zero dropped: same product
		"03600029145":     "",               // check digit dropped: not guessed
		"0036000291452":   "00036000291452", // EAN-13 spelling of the same code
		"00036000291452":  "00036000291452",
		"036000291453":    "", // bad check digit
		"000000000000":    "", // placeholder
		"1234567":         "", // too short
		"100500003500800": "", // too long
		"03600029145A":    "",
		" 036000291452 ":  "00036000291452",
	}
	for raw, want := range cases {
		got, ok := normalizeGTIN(raw)
		if got != want || ok != (want != "") {
			t.Errorf("normalizeGTIN(%q) = %q, %v; want %q", raw, got, ok, want)
		}
	}
}

func brandedMeta() *catalogMeta {
	return &catalogMeta{
		nutrientsByFDC: map[string]nutrientInfo{"208": {1, "kcal"}, "203": {2, "g"}, "539": {7, "g"}},
		units:          map[string]unitInfo{"g": {"mass", ptr(1)}, "kcal": {"energy", ptr(1)}},
	}
}

func TestPlanBrandedFood(t *testing.T) {
	f := food(t, `{"fdcId":5,"description":"GRANOLA","brandOwner":"MICHELE'S","brandName":"  ","gtinUpc":"036000291452",
	  "servingSize":28,"servingSizeUnit":"GRM","householdServingFullText":"0.25  cup","brandedFoodCategory":"Cereal",
	  "foodNutrients":[
	    {"amount":500,"nutrient":{"number":"208","name":"Energy","unitName":"kcal"},"foodNutrientDerivation":{"code":"LCCS","description":"Calculated from value per serving size measure"}},
	    {"amount":10.7,"nutrient":{"number":"203","name":"Protein","unitName":"g"},"foodNutrientDerivation":{"code":"LCCS","description":"Calculated from value per serving size measure"}},
	    {"amount":21.4,"nutrient":{"number":"539","name":"Sugars, added","unitName":"g"},"foodNutrientDerivation":{"code":"LCCD","description":"Calculated from a daily value percentage per serving size measure"}}]}`)
	st := newStats()
	p, skip := brandedMeta().planFood(f, "FDC_BRANDED", st)
	if skip != "" {
		t.Fatal(skip)
	}
	if p.Kind != "branded" || p.Basis != "per_100g" || p.Brand == nil || *p.Brand != "MICHELE'S" || p.GTIN != "00036000291452" {
		t.Errorf("plan = %+v (brand %v)", p, p.Brand)
	}
	if p.Energy.Method != "label" || p.Energy.Kcal == nil || *p.Energy.Kcal != 500 {
		t.Errorf("energy = %+v", p.Energy)
	}
	if len(p.Nutrients) != 2 {
		t.Fatalf("nutrients = %+v", p.Nutrients)
	}
	for _, n := range p.Nutrients {
		if n.Derivation == nil || *n.Derivation != "label" {
			t.Errorf("nutrient %d derivation %v, want label", n.NutrientID, n.Derivation)
		}
	}
	if len(p.Portions) != 1 || p.Portions[0].Label != "1 serving (0.25 cup)" || p.Portions[0].GramWeight != 28 || p.Portions[0].Amount != 1 {
		t.Errorf("portions = %+v", p.Portions)
	}
	if p.Group == nil || *p.Group != (foodGroup{brandedGroupScheme, "cereal", "Cereal"}) {
		t.Errorf("group = %+v", p.Group)
	}
	if k := identityKey(f, p.GTIN); k != "gtin:00036000291452" {
		t.Errorf("identity = %s", k)
	}
}

func TestPlanBrandedVolumeAndBadUnits(t *testing.T) {
	m, st := brandedMeta(), newStats()
	p, skip := m.planFood(food(t, `{"fdcId":6,"brandName":"KEFIR CO","gtinUpc":"03600029145","servingSize":120,"servingSizeUnit":"ml"}`), "FDC_BRANDED", st)
	if skip != "" || p.Basis != "per_100ml" || len(p.Portions) != 0 || p.GTIN != "" || st.BarcodesInvalid != 1 {
		t.Errorf("volume food: skip %q plan %+v invalid %d", skip, p, st.BarcodesInvalid)
	}
	if k := identityKey(food(t, `{"fdcId":6}`), p.GTIN); k != "fdc:6" {
		t.Errorf("no barcode -> fdcId identity, got %s", k)
	}
	for _, u := range []string{"MG", "IU", "MC", ""} {
		if _, skip := m.planFood(food(t, `{"fdcId":7,"servingSize":56,"servingSizeUnit":"`+u+`"}`), "FDC_BRANDED", st); skip == "" {
			t.Errorf("serving unit %q should be skipped", u)
		}
	}
}

func TestPlanKeepsFoundationBehaviour(t *testing.T) {
	f := food(t, `{"fdcId":1,"foodNutrients":[{"amount":10,"nutrient":{"number":"203","unitName":"G"},
	  "foodNutrientDerivation":{"code":"A","description":"Analytical"}}]}`)
	p, _ := brandedMeta().planFood(f, "FDC_SR_LEGACY", newStats())
	if p.Kind != "generic" || p.Basis != "per_100g" || p.Brand != nil || p.GTIN != "" || *p.Nutrients[0].Derivation != "analytical" {
		t.Errorf("SR Legacy plan = %+v", p)
	}
}

func TestImplausibleValuesDropped(t *testing.T) {
	m := brandedMeta()
	m.nutrientsByFDC["307"] = nutrientInfo{8, "mg"}
	m.units["mg"] = unitInfo{"mass", ptr(0.001)}
	js := func(unit string, kcal, protein, sodium float64) string {
		return `{"fdcId":9,"servingSize":28,"servingSizeUnit":"` + unit + `","foodNutrients":[
		  {"amount":` + ftoa(kcal) + `,"nutrient":{"number":"208","name":"Energy","unitName":"kcal"}},
		  {"amount":` + ftoa(protein) + `,"nutrient":{"number":"203","name":"Protein","unitName":"g"}},
		  {"amount":` + ftoa(sodium) + `,"nutrient":{"number":"307","name":"Sodium, Na","unitName":"mg"}}]}`
	}
	st := newStats()
	// Within 10% of the bound: kept as published (label rounding).
	p, _ := m.planFood(food(t, js("g", 923, 105, 40000)), "FDC_BRANDED", st)
	if p.Energy.Kcal == nil || len(p.Nutrients) != 2 || len(st.ImplausibleValues) != 0 {
		t.Fatalf("near-bound values should stay: %+v %v", p, st.ImplausibleValues)
	}
	// Over it: dropped and counted, the rest of the food kept.
	p, _ = m.planFood(food(t, js("g", 2000, 10.7, 1e6)), "FDC_BRANDED", st)
	if p.Energy.Kcal != nil || p.Energy.Method != "other" || len(p.Nutrients) != 1 || p.Nutrients[0].NutrientID != 2 {
		t.Errorf("impossible values should go: %+v", p)
	}
	if st.ImplausibleValues["energy (kcal)"] != 1 || st.ImplausibleValues["307 Sodium, Na"] != 1 {
		t.Errorf("counts = %v", st.ImplausibleValues)
	}
	// Per 100 mL allows a density of 1.5: 140 g of sugar-like mass is fine.
	p, _ = m.planFood(food(t, js("ml", 1300, 140, 0)), "FDC_BRANDED", newStats())
	if p.Energy.Kcal == nil || len(p.Nutrients) != 2 {
		t.Errorf("per 100 mL bounds: %+v", p)
	}
}

func ftoa(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }
