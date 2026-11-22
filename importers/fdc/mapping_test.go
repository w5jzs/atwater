package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func food(t *testing.T, js string) *fdcFood {
	t.Helper()
	var f fdcFood
	if err := json.Unmarshal([]byte(js), &f); err != nil {
		t.Fatal(err)
	}
	return &f
}

func TestPickEnergy(t *testing.T) {
	cases := []struct {
		name, js, method string
		kcal             float64
	}{
		{"published 208 with specific factors", `{"foodNutrients":[{"amount":717,"nutrient":{"number":"208","unitName":"KCAL"}}],
		  "nutrientConversionFactors":[{"type":".CalorieConversionFactor","proteinValue":4.27,"fatValue":8.79,"carbohydrateValue":3.87}]}`,
			"atwater_specific", 717},
		{"published 208 with 4/9/4", `{"foodNutrients":[{"amount":100,"nutrient":{"number":"208","unitName":"KCAL"}}],
		  "nutrientConversionFactors":[{"type":".CalorieConversionFactor","proteinValue":4,"fatValue":9,"carbohydrateValue":4}]}`,
			"atwater_general", 100},
		{"published 208, no factors", `{"foodNutrients":[{"amount":50,"nutrient":{"number":"208","unitName":"KCAL"}}]}`, "other", 50},
		{"specific preferred over general", `{"foodNutrients":[{"amount":160,"nutrient":{"number":"957","unitName":"KCAL"}},
		  {"amount":166,"nutrient":{"number":"958","unitName":"KCAL"}}]}`, "atwater_specific", 166},
		{"general only", `{"foodNutrients":[{"amount":160,"nutrient":{"number":957,"unitName":"KCAL"}}]}`, "atwater_general", 160},
		{"kJ is not energy in kcal", `{"foodNutrients":[{"amount":600,"nutrient":{"number":"268","unitName":"kJ"}}]}`, "other", -1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := pickEnergy(food(t, c.js))
			if e.Method != c.method {
				t.Errorf("method = %s, want %s", e.Method, c.method)
			}
			if c.kcal < 0 {
				if e.Kcal != nil {
					t.Errorf("kcal = %v, want none", *e.Kcal)
				}
			} else if e.Kcal == nil || *e.Kcal != c.kcal {
				t.Errorf("kcal = %v, want %v", e.Kcal, c.kcal)
			}
		})
	}
}

func TestMapNutrients(t *testing.T) {
	m := &catalogMeta{
		nutrientsByFDC: map[string]nutrientInfo{
			"208": {1, "kcal"}, "269": {6, "g"}, "305": {303, "mg"}, "301": {301, "mg"},
		},
		units: map[string]unitInfo{"g": {"mass", ptr(1)}, "mg": {"mass", ptr(0.001)}, "kcal": {"energy", ptr(1)}},
	}
	f := food(t, `{"foodNutrients":[
	  {"amount":200,"nutrient":{"number":"208","name":"Energy","unitName":"KCAL"}},
	  {"amount":0.34,"nutrient":{"number":"269.3","name":"Sugars, Total","unitName":"G"}},
	  {"amount":0.198,"nutrient":{"number":"305","name":"Phosphorus","unitName":"G"}},
	  {"amount":5,"nutrient":{"number":"301","name":"Iron","unitName":"IU"}},
	  {"amount":1,"nutrient":{"number":"511","name":"Tryptophan","unitName":"G"}},
	  {"nutrient":{"number":"305","name":"Phosphorus","unitName":"MG"}}]}`)
	st := newStats()
	got := map[int16]float64{}
	for _, n := range m.mapNutrients(f, st) {
		got[n.NutrientID] = n.Amount
	}
	if got[6] != 0.34 {
		t.Errorf("sugars 269.3 alias: got %v", got[6])
	}
	if got[303] != 198 {
		t.Errorf("phosphorus g->mg: got %v", got[303])
	}
	if _, ok := got[1]; ok {
		t.Error("energy must be handled by pickEnergy, not mapNutrients")
	}
	if _, ok := got[301]; ok || len(st.UnitMismatches) != 1 {
		t.Errorf("IU iron should be a unit mismatch: %v", st.UnitMismatches)
	}
	if st.UnmappedNutrients["511 Tryptophan"] != 1 {
		t.Errorf("unmapped not counted: %v", st.UnmappedNutrients)
	}
}

func TestMapPortions(t *testing.T) {
	f := food(t, `{"foodPortions":[
	  {"sequenceNumber":2,"amount":1,"gramWeight":227,"measureUnit":{"name":"cup"}},
	  {"sequenceNumber":1,"amount":1,"gramWeight":5,"modifier":"pat (1\" sq, 1/3\" high)","measureUnit":{"name":"undetermined"}},
	  {"sequenceNumber":3,"amount":1,"gramWeight":0,"measureUnit":{"name":"tbsp"}},
	  {"sequenceNumber":4,"value":0.5,"gramWeight":7.5,"measureUnit":{"name":"tbsp"}}]}`)
	st := newStats()
	ps := mapPortions(f, st)
	if len(ps) != 3 || st.SkippedPortions != 1 {
		t.Fatalf("got %d portions, %d skipped", len(ps), st.SkippedPortions)
	}
	if !strings.HasPrefix(ps[0].Label, "1 pat") || ps[0].UnitCode != nil {
		t.Errorf("first by sequence should be the pat with no UCUM unit: %+v", ps[0])
	}
	if ps[1].Label != "1 cup" || ps[1].UnitCode == nil || *ps[1].UnitCode != "[cup_us]" {
		t.Errorf("cup portion: %+v", ps[1])
	}
	if ps[2].Label != "0.5 tbsp" || ps[2].Amount != 0.5 {
		t.Errorf("value fallback: %+v", ps[2])
	}
}

func TestIdentityKey(t *testing.T) {
	if k := identityKey(food(t, `{"fdcId":1,"ndbNumber":1001}`)); k != "ndb:1001" {
		t.Error(k)
	}
	if k := identityKey(food(t, `{"fdcId":7,"ndbNumber":"16158"}`)); k != "ndb:16158" {
		t.Error(k)
	}
	if k := identityKey(food(t, `{"fdcId":748967}`)); k != "fdc:748967" {
		t.Error(k)
	}
}

func TestStreamRejectsUnsupported(t *testing.T) {
	if _, err := openFoodStream(strings.NewReader(`{"BrandedFoods":[]}`)); err == nil ||
		!strings.Contains(err.Error(), "not supported") {
		t.Errorf("want not-supported error, got %v", err)
	}
	s, err := openFoodStream(strings.NewReader(`{"SRLegacyFoods":[{"fdcId":1},{"fdcId":2}]}`))
	if err != nil || s.DatasetCode != "FDC_SR_LEGACY" {
		t.Fatal(err)
	}
	n := 0
	for {
		if _, err := s.Next(); err != nil {
			break
		}
		n++
	}
	if n != 2 {
		t.Errorf("streamed %d foods", n)
	}
}
