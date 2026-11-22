package targets

import (
	"errors"
	"strings"
	"testing"
)

// testCatalog is a small, real slice of the catalog: nutrient codes and
// canonical units match catalog/seed/0001.
func testCatalog(t *testing.T) *Catalog {
	t.Helper()
	c := &Catalog{Nutrients: []Nutrient{
		{1, "energy", "kcal"}, {2, "protein", "g"}, {3, "fat", "g"}, {4, "carbohydrate", "g"},
		{5, "fiber", "g"}, {201, "vit_c", "mg"}, {202, "vit_d", "ug"}, {305, "sodium", "mg"},
	}}
	if err := c.Index(); err != nil {
		t.Fatal(err)
	}
	return c
}

// The design doc's D1 example.
const d1Example = `{
  "schema_version": 1,
  "inherit_authority": true,
  "energy": { "method": "eer" },
  "body_mass": { "basis": "reference_bmi", "reference_bmi": 25 },
  "nutrients": [
    { "nutrient": "protein",      "basis": "per_kg_body_weight", "low": 1.6, "unit": "g" },
    { "nutrient": "fat",          "basis": "pct_energy",         "low": 25, "high": 35, "unit": "%" },
    { "nutrient": "carbohydrate", "basis": "energy_remainder" },
    { "nutrient": "fiber",        "basis": "per_1000_kcal",      "low": 14, "unit": "g" },
    { "nutrient": "sodium",       "basis": "per_day",            "high": 2300, "unit": "mg" }
  ]
}`

func TestParseRulesAcceptsD1Example(t *testing.T) {
	r, err := ParseRules([]byte(d1Example), testCatalog(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nutrients) != 5 || r.Energy.Method != "eer" || !r.inheritsAuthority() {
		t.Fatalf("decoded wrongly: %+v", r)
	}
	if basis, bmi := r.bodyMassBasis(); basis != "reference_bmi" || bmi != 25 {
		t.Fatalf("body mass basis = %s %v", basis, bmi)
	}
}

func TestParseRulesRejects(t *testing.T) {
	cases := map[string]struct{ doc, want string }{
		// JSON Schema (shape)
		"wrong schema version":  {`{"schema_version":2,"nutrients":[]}`, "/schema_version"},
		"unknown top-level key": {`{"schema_version":1,"nutrients":[],"variants":[]}`, "variants"},
		"no bounds":             {`{"schema_version":1,"nutrients":[{"nutrient":"sodium","basis":"per_day","unit":"mg"}]}`, "/nutrients/0"},
		"remainder with bounds": {`{"schema_version":1,"energy":{"method":"eer"},"nutrients":[{"nutrient":"fat","basis":"energy_remainder","low":1}]}`, "/nutrients/0"},
		"remainder on sodium":   {`{"schema_version":1,"energy":{"method":"eer"},"nutrients":[{"nutrient":"sodium","basis":"energy_remainder"}]}`, "/nutrients/0"},
		"fixed without kcal":    {`{"schema_version":1,"energy":{"method":"fixed"},"nutrients":[]}`, "/energy"},
		"negative amount":       {`{"schema_version":1,"nutrients":[{"nutrient":"sodium","basis":"per_day","high":-1,"unit":"mg"}]}`, "/nutrients/0"},
		"not JSON":              {`{"schema_version":`, "not valid JSON"},
		// semantic (cross-field)
		"duplicate nutrient":   {`{"schema_version":1,"nutrients":[{"nutrient":"sodium","basis":"per_day","high":1,"unit":"mg"},{"nutrient":"sodium","basis":"per_day","low":1,"unit":"mg"}]}`, "more than once"},
		"two remainders":       {`{"schema_version":1,"energy":{"method":"eer"},"nutrients":[{"nutrient":"fat","basis":"energy_remainder"},{"nutrient":"carbohydrate","basis":"energy_remainder"}]}`, "at most one energy_remainder"},
		"pct without energy":   {`{"schema_version":1,"nutrients":[{"nutrient":"fat","basis":"pct_energy","low":20,"unit":"%"}]}`, "needs an energy rule"},
		"remainder no energy":  {`{"schema_version":1,"nutrients":[{"nutrient":"fat","basis":"energy_remainder"}]}`, "needs an energy rule"},
		"wrong unit":           {`{"schema_version":1,"nutrients":[{"nutrient":"sodium","basis":"per_day","high":2.3,"unit":"g"}]}`, "canonical \"mg\""},
		"pct without percent":  {`{"schema_version":1,"energy":{"method":"eer"},"nutrients":[{"nutrient":"fat","basis":"pct_energy","low":20,"unit":"g"}]}`, "unit must be %"},
		"unknown nutrient":     {`{"schema_version":1,"nutrients":[{"nutrient":"unobtainium","basis":"per_day","low":1,"unit":"mg"}]}`, "unknown nutrient code"},
		"low above high":       {`{"schema_version":1,"nutrients":[{"nutrient":"sodium","basis":"per_day","low":3,"high":2,"unit":"mg"}]}`, "low is above high"},
		"energy as a nutrient": {`{"schema_version":1,"nutrients":[{"nutrient":"energy","basis":"per_day","low":2000,"unit":"kcal"}]}`, "energy rule"},
		"bmi with measured":    {`{"schema_version":1,"body_mass":{"basis":"measured","reference_bmi":25},"nutrients":[]}`, "reference_bmi only applies"},
	}
	cat := testCatalog(t)
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseRules([]byte(c.doc), cat)
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("want ValidationError, got %v", err)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want error mentioning %q, got: %v", c.want, err)
			}
		})
	}
}

func TestParseRulesReportsAllProblems(t *testing.T) {
	doc := `{"schema_version":1,"nutrients":[
	  {"nutrient":"sodium","basis":"per_day","high":2.3,"unit":"g"},
	  {"nutrient":"unobtainium","basis":"per_day","low":1,"unit":"mg"}]}`
	_, err := ParseRules([]byte(doc), testCatalog(t))
	var ve *ValidationError
	if !errors.As(err, &ve) || len(ve.Problems) != 2 {
		t.Fatalf("want 2 problems, got %v", err)
	}
}

func TestCatalogPlanProblems(t *testing.T) {
	cat := testCatalog(t)
	cat.Values = []ReferenceValue{{Authority: "NASEM_DRI", Edition: "e", LifeStage: "M", Nutrient: "vit_c",
		ValueType: "UL", Basis: BasisPerDay, High: f(2000), Unit: "mg", AppliesTo: "total_intake"}}
	r := &Rules{SchemaVersion: 1, Nutrients: []NutrientRule{{Nutrient: "vit_c", Basis: BasisPerDay, Low: f(2500), Unit: "mg"}}}
	if p := CatalogPlanProblems(r, cat, "NASEM_DRI", "e", []string{"M"}); len(p) != 1 {
		t.Fatalf("want 1 problem, got %v", p)
	}
	r.Nutrients[0].Low = f(500)
	if p := CatalogPlanProblems(r, cat, "NASEM_DRI", "e", []string{"M"}); len(p) != 0 {
		t.Fatalf("want none, got %v", p)
	}
}
