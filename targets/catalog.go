// Package targets resolves a person's daily nutrient targets from the
// authority's reference values, their assigned diet plan, their overrides and
// their body (design 0001). It is pure: callers gather inputs from the tenant
// shard and the cached catalog, and write the results.
package targets

import "fmt"

// Catalog is the slice of the catalog the resolver needs, as the caller loads
// it from ref.* (normally through the Valkey cache).
type Catalog struct {
	Nutrients       []Nutrient
	LifeStages      []LifeStage
	Values          []ReferenceValue
	EnergyEquations []EnergyEquation

	byCode map[string]Nutrient
	byID   map[int16]Nutrient
}

type Nutrient struct {
	ID   int16
	Code string
	Unit string // canonical unit
}

type LifeStage struct {
	Code               string
	Authority          string
	Sex                string // female | male | any
	AgeMinMonths       int
	AgeMaxMonths       *int // exclusive; nil = open-ended
	PhysiologicalState string
}

type ReferenceValue struct {
	Authority string
	Edition   string
	LifeStage string
	Nutrient  string // code
	ValueType string // RDA, AI, UL, AMDR, CDRR, DG, ...
	Basis     string // per_day, pct_energy, per_kg_body_weight, per_1000_kcal
	Low, High *float64
	Unit      string
	AppliesTo string // total_intake, supplements_only, food_only
}

type EnergyEquation struct {
	Authority     string
	Edition       string
	LifeStage     string
	ActivityLevel string
	Intercept     float64
	AgeYears      float64
	HeightCM      float64
	WeightKG      float64
	Extra         float64
}

// Index builds the lookup maps. Call it once after filling the slices.
func (c *Catalog) Index() error {
	c.byCode = make(map[string]Nutrient, len(c.Nutrients))
	c.byID = make(map[int16]Nutrient, len(c.Nutrients))
	for _, n := range c.Nutrients {
		if _, dup := c.byCode[n.Code]; dup {
			return fmt.Errorf("catalog: duplicate nutrient code %q", n.Code)
		}
		c.byCode[n.Code] = n
		c.byID[n.ID] = n
	}
	return nil
}

func (c *Catalog) nutrient(code string) (Nutrient, bool) {
	n, ok := c.byCode[code]
	return n, ok
}

func (c *Catalog) nutrientByID(id int16) (Nutrient, bool) {
	n, ok := c.byID[id]
	return n, ok
}
