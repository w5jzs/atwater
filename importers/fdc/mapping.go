package main

import (
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// catalogMeta is what the importer reads from the catalog before it starts:
// the nutrients it knows and the units it can convert between.
type catalogMeta struct {
	nutrientsByFDC map[string]nutrientInfo // FDC nutrient number -> Atwater nutrient
	units          map[string]unitInfo     // UCUM code -> dimension/scale
}

type nutrientInfo struct {
	ID   int16
	Unit string
}

type unitInfo struct {
	Dimension string
	ToBase    *float64
}

// FDC nutrient numbers that mean the same thing as one Atwater nutrient.
// Foundation foods report total sugars as 269.3 rather than SR Legacy's 269.
var fdcNumberAliases = map[string]string{
	"269.3": "269",
}

// Energy numbers handled by pickEnergy, not by the generic mapping.
const (
	fdcEnergyKcal          = "208"
	fdcEnergyKJ            = "268"
	fdcEnergyAtwaterGen    = "957"
	fdcEnergyAtwaterSpec   = "958"
	atwaterEnergyNutrientN = "208"
)

// FDC unitName -> UCUM code. Keys are normalized by fdcUnitCode.
var fdcUnits = map[string]string{
	"G": "g", "MG": "mg", "UG": "ug", "MCG": "ug", "KCAL": "kcal", "KJ": "kJ",
	"MG_ATE": "mg", // vitamin E as alpha-tocopherol equivalents
}

// fdcUnitCode maps an FDC unitName to UCUM. Real FDC downloads spell
// micrograms "µg" (U+00B5 MICRO SIGN), which strings.ToUpper turns into
// Greek capital MU, so micro signs are folded to "u" before the lookup.
func fdcUnitCode(name string) string {
	name = strings.NewReplacer("µ", "u", "μ", "u").Replace(strings.TrimSpace(name))
	return fdcUnits[strings.ToUpper(name)]
}

type mappedNutrient struct {
	NutrientID int16
	Amount     float64
	Derivation *string
}

type energyResult struct {
	Kcal    *float64
	Method  string // ref.food_version.energy_method
	Protein *float64
	Fat     *float64
	Carb    *float64
}

// importStats counts what happened, for the run log and the final report.
type importStats struct {
	FoodsRead          int            `json:"foods_read"`
	FoodsInserted      int            `json:"foods_inserted"`
	FoodsAlreadyLoaded int            `json:"foods_already_loaded"`
	NewFoodIdentities  int            `json:"new_food_identities"`
	VersionsSuperseded int            `json:"versions_superseded"`
	NutrientRows       int            `json:"nutrient_rows"`
	PortionRows        int            `json:"portion_rows"`
	FoodsWithoutEnergy int            `json:"foods_without_energy"`
	EnergyMethods      map[string]int `json:"energy_methods"`
	UnmappedNutrients  map[string]int `json:"unmapped_nutrients"`
	UnitMismatches     map[string]int `json:"unit_mismatches"`
	SkippedPortions    int            `json:"skipped_portions"`
}

func newStats() *importStats {
	return &importStats{
		EnergyMethods:     map[string]int{},
		UnmappedNutrients: map[string]int{},
		UnitMismatches:    map[string]int{},
	}
}

// mapNutrients turns FDC food nutrients into Atwater rows (per 100 g, in the
// nutrient's canonical unit). Energy is excluded here; see pickEnergy.
func (m *catalogMeta) mapNutrients(f *fdcFood, st *importStats) []mappedNutrient {
	seen := map[int16]bool{}
	var out []mappedNutrient
	for _, fn := range f.FoodNutrients {
		num := string(fn.Nutrient.Number)
		if fn.Amount == nil || num == "" || isEnergyNumber(num) {
			continue
		}
		if alias, ok := fdcNumberAliases[num]; ok {
			num = alias
		}
		info, ok := m.nutrientsByFDC[num]
		if !ok {
			st.UnmappedNutrients[num+" "+fn.Nutrient.Name]++
			continue
		}
		amount, ok := m.convert(*fn.Amount, fdcUnitCode(fn.Nutrient.UnitName), info.Unit)
		if !ok {
			st.UnitMismatches[num+" "+fn.Nutrient.UnitName+"->"+info.Unit]++
			continue
		}
		if amount < 0 || seen[info.ID] {
			continue
		}
		seen[info.ID] = true
		out = append(out, mappedNutrient{NutrientID: info.ID, Amount: round6(amount), Derivation: derivation(fn)})
	}
	return out
}

func isEnergyNumber(n string) bool {
	switch n {
	case fdcEnergyKcal, fdcEnergyKJ, fdcEnergyAtwaterGen, fdcEnergyAtwaterSpec:
		return true
	}
	return false
}

// convert moves an amount between units of the same dimension.
func (m *catalogMeta) convert(v float64, from, to string) (float64, bool) {
	if from == "" || to == "" {
		return 0, false
	}
	if from == to {
		return v, true
	}
	a, okA := m.units[from]
	b, okB := m.units[to]
	if !okA || !okB || a.Dimension != b.Dimension || a.ToBase == nil || b.ToBase == nil || *b.ToBase == 0 {
		return 0, false
	}
	return v * *a.ToBase / *b.ToBase, true
}

// pickEnergy stores energy as the source reports it, recording how it was
// derived (never recomputed from macros). Preference: the published Energy
// (208), then Atwater-specific (958), then Atwater-general (957).
func pickEnergy(f *fdcFood) energyResult {
	byNum := map[string]float64{}
	for _, fn := range f.FoodNutrients {
		if fn.Amount != nil && strings.EqualFold(fn.Nutrient.UnitName, "KCAL") {
			byNum[string(fn.Nutrient.Number)] = *fn.Amount
		}
	}
	res := energyResult{}
	for _, cf := range f.ConvFactors {
		if strings.Contains(strings.ToLower(cf.Type), "calorieconversionfactor") {
			res.Protein, res.Fat, res.Carb = cf.ProteinValue, cf.FatValue, cf.CarbohydrateValue
		}
	}
	general := res.Protein != nil && res.Fat != nil && res.Carb != nil &&
		*res.Protein == 4 && *res.Fat == 9 && *res.Carb == 4

	switch {
	case has(byNum, fdcEnergyKcal):
		v := byNum[fdcEnergyKcal]
		res.Kcal = &v
		switch {
		case res.Protein == nil:
			res.Method = "other"
		case general:
			res.Method = "atwater_general"
		default:
			res.Method = "atwater_specific"
		}
	case has(byNum, fdcEnergyAtwaterSpec):
		v := byNum[fdcEnergyAtwaterSpec]
		res.Kcal, res.Method = &v, "atwater_specific"
	case has(byNum, fdcEnergyAtwaterGen):
		v := byNum[fdcEnergyAtwaterGen]
		res.Kcal, res.Method = &v, "atwater_general"
		res.Protein, res.Fat, res.Carb = ptr(4), ptr(9), ptr(4)
	default:
		res.Method = "other"
	}
	return res
}

func has(m map[string]float64, k string) bool { _, ok := m[k]; return ok }
func ptr(v float64) *float64                  { return &v }
func round6(v float64) float64                { return math.Round(v*1e6) / 1e6 }

// derivation maps FDC's derivation description onto the catalog's enum.
func derivation(fn fdcFoodNutrient) *string {
	if fn.Derivation == nil {
		return nil
	}
	d := strings.ToLower(fn.Derivation.Description)
	var v string
	switch {
	case strings.Contains(d, "assumed zero"):
		v = "assumed_zero"
	case strings.Contains(d, "analytical"):
		v = "analytical"
	case strings.Contains(d, "label"):
		v = "label"
	case strings.Contains(d, "impute"), strings.Contains(d, "borrowed"):
		v = "imputed"
	case strings.Contains(d, "calculated"), strings.Contains(d, "summed"), strings.Contains(d, "formula"):
		v = "calculated"
	default:
		return nil
	}
	return &v
}

type mappedPortion struct {
	Label      string
	Amount     float64
	UnitCode   *string
	GramWeight float64
	Seq        int
}

var portionUnits = map[string]string{
	"cup": "[cup_us]", "tablespoon": "[tbs_us]", "tbsp": "[tbs_us]",
	"teaspoon": "[tsp_us]", "tsp": "[tsp_us]", "fl oz": "[foz_us]",
	"ml": "mL", "milliliter": "mL", "oz": "[oz_av]", "ounce": "[oz_av]",
}

var spaces = regexp.MustCompile(`\s+`)

// mapPortions builds household measures; each must resolve to grams.
func mapPortions(f *fdcFood, st *importStats) []mappedPortion {
	var out []mappedPortion
	for _, p := range f.FoodPortions {
		if p.GramWeight <= 0 {
			st.SkippedPortions++
			continue
		}
		amount := p.Amount
		if amount <= 0 {
			amount = p.Value
		}
		if amount <= 0 {
			amount = 1
		}
		unitName := strings.TrimSpace(p.MeasureUnit.Name)
		if strings.EqualFold(unitName, "undetermined") {
			unitName = ""
		}
		desc := strings.TrimSpace(p.Modifier)
		if desc == "" {
			desc = strings.TrimSpace(p.PortionDescription)
		}
		label := spaces.ReplaceAllString(strings.TrimSpace(
			strconv.FormatFloat(amount, 'f', -1, 64)+" "+unitName+" "+desc), " ")
		if unitName == "" && desc == "" {
			st.SkippedPortions++
			continue
		}
		mp := mappedPortion{Label: label, Amount: amount, GramWeight: math.Round(p.GramWeight*1000) / 1000, Seq: p.SequenceNumber}
		if u, ok := portionUnits[strings.ToLower(unitName)]; ok {
			mp.UnitCode = &u
		}
		out = append(out, mp)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Seq < out[j].Seq })
	return out
}

// identityKey is the release-stable key for a food: the NDB number when
// FDC provides one, otherwise the fdcId.
func identityKey(f *fdcFood) string {
	if n := strings.TrimSpace(string(f.NdbNumber)); n != "" && n != "0" {
		return "ndb:" + n
	}
	return "fdc:" + strconv.Itoa(f.FdcID)
}

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// categoryCode gives a stable group code for the FDC food category.
func categoryCode(c *fdcCategory) (code, name string, ok bool) {
	if c == nil || strings.TrimSpace(c.Description) == "" {
		return "", "", false
	}
	name = strings.TrimSpace(c.Description)
	if s := strings.TrimSpace(string(c.Code)); s != "" {
		return s, name, true
	}
	return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(name), "-"), "-"), name, true
}
