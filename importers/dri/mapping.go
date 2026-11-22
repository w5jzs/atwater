package main

// What each printed table row and column means in catalog terms. Every
// life-stage label and every column header in the raw CSVs must appear here,
// either mapped or skipped with a reason: an unknown header is an error, so a
// new or renamed column can't be silently dropped.

const (
	authority = "NASEM_DRI"
	edition   = "consolidated-2019"
	sourceURL = "https://www.nationalacademies.org/read/25353/chapter/28"
	s2URL     = "https://www.nationalacademies.org/read/25353/chapter/2"
)

type lifeStage struct {
	Code      string
	Sex       string // female | male | any
	MinMonths int
	MaxMonths int // exclusive; 0 = open-ended
	State     string
	Label     string
}

func ls(code, sex string, lo, hi int, state, label string) lifeStage {
	return lifeStage{code, sex, lo, hi, state, label}
}

// Life-stage groups, keyed by the label as printed in the RDA/AI and UL tables.
// Infant groups were 0-5.9 and 6-11.9 months (table footnotes), hence 0-6, 6-12.
var lifeStages = map[string]lifeStage{
	"Infants 0–6 mo":    ls("NASEM_DRI/I/0-6mo", "any", 0, 6, "none", "Infants 0-6 mo"),
	"Infants 7–12 mo":   ls("NASEM_DRI/I/7-12mo", "any", 6, 12, "none", "Infants 7-12 mo"),
	"Children 1–3 y":    ls("NASEM_DRI/C/1-3y", "any", 12, 48, "none", "Children 1-3 y"),
	"Children 4–8 y":    ls("NASEM_DRI/C/4-8y", "any", 48, 108, "none", "Children 4-8 y"),
	"Males 9–13 y":      ls("NASEM_DRI/M/9-13y", "male", 108, 168, "none", "Males 9-13 y"),
	"Males 14–18 y":     ls("NASEM_DRI/M/14-18y", "male", 168, 228, "none", "Males 14-18 y"),
	"Males 19–30 y":     ls("NASEM_DRI/M/19-30y", "male", 228, 372, "none", "Males 19-30 y"),
	"Males 31–50 y":     ls("NASEM_DRI/M/31-50y", "male", 372, 612, "none", "Males 31-50 y"),
	"Males 51–70 y":     ls("NASEM_DRI/M/51-70y", "male", 612, 852, "none", "Males 51-70 y"),
	"Males > 70 y":      ls("NASEM_DRI/M/71+y", "male", 852, 0, "none", "Males > 70 y"),
	"Females 9–13 y":    ls("NASEM_DRI/F/9-13y", "female", 108, 168, "none", "Females 9-13 y"),
	"Females 14–18 y":   ls("NASEM_DRI/F/14-18y", "female", 168, 228, "none", "Females 14-18 y"),
	"Females 19–30 y":   ls("NASEM_DRI/F/19-30y", "female", 228, 372, "none", "Females 19-30 y"),
	"Females 31–50 y":   ls("NASEM_DRI/F/31-50y", "female", 372, 612, "none", "Females 31-50 y"),
	"Females 51–70 y":   ls("NASEM_DRI/F/51-70y", "female", 612, 852, "none", "Females 51-70 y"),
	"Females > 70 y":    ls("NASEM_DRI/F/71+y", "female", 852, 0, "none", "Females > 70 y"),
	"Pregnancy 14–18 y": ls("NASEM_DRI/P/14-18y", "female", 168, 228, "pregnant", "Pregnancy 14-18 y"),
	"Pregnancy 19–30 y": ls("NASEM_DRI/P/19-30y", "female", 228, 372, "pregnant", "Pregnancy 19-30 y"),
	"Pregnancy 31–50 y": ls("NASEM_DRI/P/31-50y", "female", 372, 612, "pregnant", "Pregnancy 31-50 y"),
	"Lactation 14–18 y": ls("NASEM_DRI/L/14-18y", "female", 168, 228, "lactating", "Lactation 14-18 y"),
	"Lactation 19–30 y": ls("NASEM_DRI/L/19-30y", "female", 228, 372, "lactating", "Lactation 19-30 y"),
	"Lactation 31–50 y": ls("NASEM_DRI/L/31-50y", "female", 372, 612, "lactating", "Lactation 31-50 y"),
}

// Groups the AMDR and CDRR tables print as wider populations, expanded to the
// RDA/AI table's groups. Pregnancy and lactation take the adult (or 14-18)
// AMDR; their CDRR rows are printed explicitly (Summary Table S-2).
var populationGroups = map[string][]string{
	"Children 1–3 y":      {"Children 1–3 y"},
	"Children 4–8 y":      {"Children 4–8 y"},
	"Children 4–18 y":     {"Children 4–8 y", "Males 9–13 y", "Males 14–18 y", "Females 9–13 y", "Females 14–18 y", "Pregnancy 14–18 y", "Lactation 14–18 y"},
	"Adolescents 9–13 y":  {"Males 9–13 y", "Females 9–13 y"},
	"Adolescents 14–18 y": {"Males 14–18 y", "Females 14–18 y"},
	"Adults":              {"Males 19–30 y", "Males 31–50 y", "Males 51–70 y", "Males > 70 y", "Females 19–30 y", "Females 31–50 y", "Females 51–70 y", "Females > 70 y", "Pregnancy 19–30 y", "Pregnancy 31–50 y", "Lactation 19–30 y", "Lactation 31–50 y"},
	"Adults ≥ 19 y":       {"Males 19–30 y", "Males 31–50 y", "Males 51–70 y", "Males > 70 y", "Females 19–30 y", "Females 31–50 y", "Females 51–70 y", "Females > 70 y"},
	"Pregnancy 14–18 y":   {"Pregnancy 14–18 y"},
	"Pregnancy 19–30 y":   {"Pregnancy 19–30 y"},
	"Pregnancy 31–50 y":   {"Pregnancy 31–50 y"},
	"Lactation 14–18 y":   {"Lactation 14–18 y"},
	"Lactation 19–30 y":   {"Lactation 19–30 y"},
	"Lactation 31–50 y":   {"Lactation 31–50 y"},
}

// column says how one printed column loads. Skip != "" means it doesn't load.
type column struct {
	Nutrient  string  // ref.nutrient.code
	Unit      string  // catalog canonical unit of the stored amount
	Factor    float64 // printed unit -> canonical unit
	AppliesTo string  // for ULs
	Note      string
	Skip      string
}

func col(nutrient, unit string, factor float64, note string) column {
	return column{Nutrient: nutrient, Unit: unit, Factor: factor, AppliesTo: "total_intake", Note: note}
}
func skip(reason string) column { return column{Skip: reason} }

const notInCatalog = "not a catalog nutrient yet"

var rdaAIVitamins = map[string]column{
	"Vitamin A (μg/d)":        col("vit_a_rae", "ug", 1, "As retinol activity equivalents (RAE)."),
	"Vitamin C (mg/d)":        col("vit_c", "mg", 1, ""),
	"Vitamin D (μg/d)":        col("vit_d", "ug", 1, "As cholecalciferol (1 μg = 40 IU), assuming minimal sunlight."),
	"Vitamin E (mg/d)":        col("vit_e", "mg", 1, "As α-tocopherol."),
	"Vitamin K (μg/d)":        col("vit_k", "ug", 1, ""),
	"Thiamin (mg/d)":          col("thiamin", "mg", 1, ""),
	"Riboflavin (mg/d)":       col("riboflavin", "mg", 1, ""),
	"Niacin (mg/d)":           col("niacin", "mg", 1, "As niacin equivalents (NE; 1 mg niacin = 60 mg tryptophan); preformed niacin for 0-6 mo. Food data (FDC 406) is preformed niacin only."),
	"Vitamin B6 (mg/d)":       col("vit_b6", "mg", 1, ""),
	"Folate (μg/d)":           col("folate_dfe", "ug", 1, "As dietary folate equivalents (DFE)."),
	"Vitamin B12 (μg/d)":      col("vit_b12", "ug", 1, ""),
	"Pantothenic Acid (mg/d)": col("pantothenic_acid", "mg", 1, ""),
	"Biotin (μg/d)":           skip(notInCatalog),
	"Choline (mg/d)":          col("choline", "mg", 1, "AI set with limited data; may be met by endogenous synthesis at some life stages."),
}

var rdaAIElements = map[string]column{
	"Calcium (mg/d)":    col("calcium", "mg", 1, ""),
	"Chromium (μg/d)":   skip(notInCatalog),
	"Copper (μg/d)":     col("copper", "mg", 0.001, ""),
	"Fluoride (mg/d)":   skip(notInCatalog),
	"Iodine (μg/d)":     skip(notInCatalog),
	"Iron (mg/d)":       col("iron", "mg", 1, ""),
	"Magnesium (mg/d)":  col("magnesium", "mg", 1, ""),
	"Manganese (mg/d)":  col("manganese", "mg", 1, ""),
	"Molybdenum (μg/d)": skip(notInCatalog),
	"Phosphorus (mg/d)": col("phosphorus", "mg", 1, ""),
	"Selenium (μg/d)":   col("selenium", "ug", 1, ""),
	"Zinc (mg/d)":       col("zinc", "mg", 1, ""),
	"Potassium (mg/d)":  col("potassium", "mg", 1, ""),
	"Sodium (mg/d)":     col("sodium", "mg", 1, ""),
	"Chloride (g/d)":    skip(notInCatalog),
}

var rdaAIMacros = map[string]column{
	"Total Water (L/d)":      skip("total water includes beverages and drinking water; the catalog's water nutrient is water in food. Belongs with hydration targets."),
	"Carbohydrate (g/d)":     col("carbohydrate", "g", 1, ""),
	"Total Fiber (g/d)":      col("fiber", "g", 1, ""),
	"Fat (g/d)":              col("fat", "g", 1, ""),
	"Linoleic Acid (g/d)":    skip(notInCatalog),
	"α-Linolenic Acid (g/d)": skip(notInCatalog),
	"Protein (g/d)":          col("protein", "g", 1, "For the reference body weight (adults 0.8 g/kg). Per-kg targets use the per_kg_body_weight basis where seeded."),
}

var amdrCols = map[string]column{
	"Fat (% of energy)": col("fat", "%", 1, ""),
	"n-6 polyunsaturated fatty acids (linoleic acid) (% of energy)":    skip(notInCatalog),
	"n-3 polyunsaturated fatty acids (α-linolenic acid) (% of energy)": skip(notInCatalog),
	"Carbohydrate (% of energy)":                                       col("carbohydrate", "%", 1, ""),
	"Protein (% of energy)":                                            col("protein", "%", 1, ""),
}

func supp(nutrient, unit string, factor float64, note string) column {
	c := col(nutrient, unit, factor, note)
	c.AppliesTo = "supplements_only"
	return c
}

const noUL = "no UL established (all ND)"

var ulVitamins = map[string]column{
	"Vitamin A (μg/d)":  skip("UL applies to preformed vitamin A only; the catalog nutrient is RAE, which includes carotenoids. Needs a retinol nutrient."),
	"Vitamin C (mg/d)":  col("vit_c", "mg", 1, ""),
	"Vitamin D (μg/d)":  col("vit_d", "ug", 1, ""),
	"Vitamin E (mg/d)":  supp("vit_e", "mg", 1, "Applies to synthetic α-tocopherol from supplements, fortified foods or both."),
	"Vitamin K":         skip(noUL),
	"Thiamin":           skip(noUL),
	"Riboflavin":        skip(noUL),
	"Niacin (mg/d)":     supp("niacin", "mg", 1, "Applies to synthetic forms from supplements, fortified foods or both."),
	"Vitamin B6 (mg/d)": col("vit_b6", "mg", 1, ""),
	"Folate (μg/d)":     skip("UL is synthetic folic acid in μg, not DFE; needs the folic acid nutrient (FDC 431)."),
	"Vitamin B12":       skip(noUL),
	"Pantothenic Acid":  skip(noUL),
	"Biotin":            skip(noUL),
	"Choline (g/d)":     col("choline", "mg", 1000, ""),
	"Carotenoids":       skip(noUL),
}

var ulElements = map[string]column{
	"Arsenic":           skip(noUL),
	"Boron (mg/d)":      skip(notInCatalog),
	"Calcium (mg/d)":    col("calcium", "mg", 1, ""),
	"Chromium":          skip(noUL),
	"Copper (μg/d)":     col("copper", "mg", 0.001, ""),
	"Fluoride (mg/d)":   skip(notInCatalog),
	"Iodine (μg/d)":     skip(notInCatalog),
	"Iron (mg/d)":       col("iron", "mg", 1, ""),
	"Magnesium (mg/d)":  supp("magnesium", "mg", 1, "From pharmacological agents only; excludes food and water."),
	"Manganese (mg/d)":  col("manganese", "mg", 1, ""),
	"Molybdenum (μg/d)": skip(notInCatalog),
	"Nickel (mg/d)":     skip(notInCatalog),
	"Phosphorus (g/d)":  col("phosphorus", "mg", 1000, ""),
	"Potassium":         skip(noUL),
	"Selenium (μg/d)":   col("selenium", "ug", 1, ""),
	"Silicon":           skip(noUL),
	"Sulfate":           skip(noUL),
	"Vanadium (mg/d)":   skip(notInCatalog),
	"Zinc (mg/d)":       col("zinc", "mg", 1, ""),
	"Sodium":            skip(noUL),
	"Chloride (g/d)":    skip(notInCatalog),
}

var cdrrCols = map[string]column{
	"Sodium CDRR (mg/d)": col("sodium", "mg", 1, ""),
	"printed_as":         skip("text as printed, kept for review"),
	"source_table":       skip("provenance, kept for review"),
}

// tableSpec ties a raw CSV to its column map and to how its values load.
type tableSpec struct {
	File   string
	Cols   map[string]column
	Kind   string              // rda_ai | amdr | ul | cdrr
	Groups map[string][]string // nil = labels are life-stage labels
	Source string
}

var tables = []tableSpec{
	{"rda_ai_vitamins.csv", rdaAIVitamins, "rda_ai", nil, sourceURL},
	{"rda_ai_elements.csv", rdaAIElements, "rda_ai", nil, sourceURL},
	{"rda_ai_macronutrients.csv", rdaAIMacros, "rda_ai", nil, sourceURL},
	{"amdr.csv", amdrCols, "amdr", populationGroups, sourceURL},
	{"ul_vitamins.csv", ulVitamins, "ul", nil, sourceURL},
	{"ul_elements.csv", ulElements, "ul", nil, sourceURL},
	{"cdrr_sodium.csv", cdrrCols, "cdrr", populationGroups, sourceURL},
}
