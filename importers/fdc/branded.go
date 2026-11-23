package main

import (
	"math"
	"strconv"
	"strings"
)

// foodPlan is everything the importer writes for one food, worked out
// without touching the database. The dry run and the import both build it,
// so their counts can't drift apart.
type foodPlan struct {
	Kind      string // ref.food_version.food_kind
	Basis     string // per_100g | per_100ml
	Brand     *string
	GTIN      string // GTIN-14 for ref.food_barcode; "" when the source has no usable barcode
	Energy    energyResult
	Nutrients []mappedNutrient
	Portions  []mappedPortion
	Group     *foodGroup
}

type foodGroup struct{ Scheme, Code, Name string }

const brandedGroupScheme = "FDC_BRANDED_CATEGORY"

// planFood maps one FDC food. A non-empty skip reason means the food can't
// be imported faithfully and is left out (counted in the report).
func (m *catalogMeta) planFood(f *fdcFood, datasetCode string, st *importStats) (p *foodPlan, skip string) {
	p = &foodPlan{Basis: "per_100g", Energy: pickEnergy(f)}
	switch datasetCode {
	case "FDC_BRANDED":
		basis, ok := brandedBasis(f.ServingSizeUnit)
		if !ok {
			return nil, "serving unit " + strconv.Quote(strings.TrimSpace(f.ServingSizeUnit))
		}
		p.Kind, p.Basis = "branded", basis
		p.Brand = brandOf(f)
		if g, ok := normalizeGTIN(f.GtinUpc); ok {
			p.GTIN = g
		} else if strings.TrimSpace(f.GtinUpc) != "" {
			st.BarcodesInvalid++
		}
		// Branded nutrients come from the label; there are no conversion
		// factors, so pickEnergy can only have found the published 208.
		if p.Energy.Kcal != nil {
			p.Energy.Method = "label"
		}
		if c := strings.TrimSpace(f.BrandedCategory); c != "" {
			p.Group = &foodGroup{brandedGroupScheme, slug(c), c}
		}
		p.Portions = brandedPortions(f, p.Basis)
	default:
		p.Kind = "foundation"
		if datasetCode == "FDC_SR_LEGACY" {
			p.Kind = "generic"
		}
		if code, name, ok := categoryCode(f.FoodCategory); ok {
			p.Group = &foodGroup{foodGroupScheme, code, name}
		}
		p.Portions = mapPortions(f, st)
	}
	p.Nutrients = m.mapNutrients(f, st)
	return p, ""
}

// countPlan adds a planned food's rows to the report. Rows written are
// counted by the importer itself; this covers what both paths share.
func (st *importStats) countPlan(p *foodPlan) {
	st.EnergyMethods[p.Energy.Method]++
	if p.Energy.Kcal == nil {
		st.FoodsWithoutEnergy++
	}
	if p.GTIN != "" {
		st.Barcodes++
	}
	if p.Basis == "per_100ml" {
		st.FoodsPer100mL++
	}
}

// brandedBasis reads servingSizeUnit, which also fixes the nutrient basis:
// Branded nutrients are per 100 of the serving's unit (checked against the
// label's per-serving calories). FDC also has a few thousand foods whose
// unit says MG, IU or MC although the numbers behave like grams or
// millilitres; with no way to tell which, those are skipped.
func brandedBasis(unit string) (string, bool) {
	switch strings.ToUpper(strings.TrimSpace(unit)) {
	case "G", "GRM", "GM":
		return "per_100g", true
	case "ML", "MLT":
		return "per_100ml", true
	}
	return "", false
}

// brandedPortions turns the label serving into a portion. Portions resolve
// to grams, so a serving in millilitres (no density) gets none.
func brandedPortions(f *fdcFood, basis string) []mappedPortion {
	if basis != "per_100g" || f.ServingSize == nil || *f.ServingSize <= 0 {
		return nil
	}
	label := "1 serving"
	if h := spaces.ReplaceAllString(strings.TrimSpace(f.HouseholdServing), " "); h != "" {
		label += " (" + h + ")"
	}
	return []mappedPortion{{Label: label, Amount: 1, GramWeight: math.Round(*f.ServingSize*1000) / 1000}}
}

func brandOf(f *fdcFood) *string {
	for _, b := range []string{f.BrandName, f.BrandOwner} {
		if b = strings.TrimSpace(b); b != "" {
			return &b
		}
	}
	return nil
}

// normalizeGTIN zero-pads a barcode to GTIN-14 and checks it the way
// ref.gtin14_ok does (catalog migration 0009): 8-14 digits, valid check
// digit, not all zeros. FDC's 11-digit codes are mostly UPC-A with the
// check digit dropped; they fail here rather than get a guessed digit.
func normalizeGTIN(raw string) (string, bool) {
	s := strings.TrimSpace(raw)
	if len(s) < 8 || len(s) > 14 {
		return "", false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return "", false
		}
	}
	g := strings.Repeat("0", 14-len(s)) + s
	if g == "00000000000000" {
		return "", false
	}
	sum := 0
	for i := 0; i < 13; i++ {
		d := int(g[i] - '0')
		if i%2 == 0 {
			d *= 3
		}
		sum += d
	}
	if (10-sum%10)%10 != int(g[13]-'0') {
		return "", false
	}
	return g, true
}

func slug(s string) string {
	return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(s), "-"), "-")
}
