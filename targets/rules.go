package targets

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// Rules is a diet-plan rules document, rules_schema_version 1 (design 0001 D1).
type Rules struct {
	SchemaVersion    int            `json:"schema_version"`
	InheritAuthority *bool          `json:"inherit_authority,omitempty"`
	Energy           *EnergyRule    `json:"energy,omitempty"`
	BodyMass         *BodyMassRule  `json:"body_mass,omitempty"`
	Nutrients        []NutrientRule `json:"nutrients"`
}

type EnergyRule struct {
	Method string   `json:"method"` // eer | fixed
	Kcal   *float64 `json:"kcal,omitempty"`
}

type BodyMassRule struct {
	Basis        string   `json:"basis"` // measured | reference_bmi
	ReferenceBMI *float64 `json:"reference_bmi,omitempty"`
}

type NutrientRule struct {
	Nutrient string   `json:"nutrient"`
	Basis    string   `json:"basis"` // per_day | pct_energy | per_kg_body_weight | per_1000_kcal | energy_remainder
	Low      *float64 `json:"low,omitempty"`
	High     *float64 `json:"high,omitempty"`
	Unit     string   `json:"unit,omitempty"`
	Note     string   `json:"note,omitempty"`
}

const (
	BasisPerDay          = "per_day"
	BasisPctEnergy       = "pct_energy"
	BasisPerKg           = "per_kg_body_weight"
	BasisPer1000Kcal     = "per_1000_kcal"
	BasisEnergyRemainder = "energy_remainder"
)

func (r *Rules) inheritsAuthority() bool { return r.InheritAuthority == nil || *r.InheritAuthority }

func (r *Rules) bodyMassBasis() (string, float64) {
	if r.BodyMass == nil {
		return "measured", 25
	}
	bmi := 25.0
	if r.BodyMass.ReferenceBMI != nil {
		bmi = *r.BodyMass.ReferenceBMI
	}
	return r.BodyMass.Basis, bmi
}

//go:embed schema/diet-plan-rules.v1.schema.json
var schemaV1 []byte

var (
	compileOnce sync.Once
	compiled    *jsonschema.Schema
	compileErr  error
)

func schema() (*jsonschema.Schema, error) {
	compileOnce.Do(func() {
		doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(schemaV1))
		if err != nil {
			compileErr = err
			return
		}
		c := jsonschema.NewCompiler()
		const url = "urn:atwater:schema:diet-plan-rules:v1"
		if err := c.AddResource(url, doc); err != nil {
			compileErr = err
			return
		}
		compiled, compileErr = c.Compile(url)
	})
	return compiled, compileErr
}

// ValidationError lists every problem found, so a plan author sees them all at once.
type ValidationError struct{ Problems []string }

func (e *ValidationError) Error() string {
	return "invalid diet-plan rules: " + strings.Join(e.Problems, "; ")
}

// ParseRules validates a rules document against the v1 JSON Schema, then the
// cross-field rules JSON Schema can't express (design 0001 D1), and decodes it.
func ParseRules(raw []byte, cat *Catalog) (*Rules, error) {
	sch, err := schema()
	if err != nil {
		return nil, fmt.Errorf("compiling rules schema: %w", err)
	}
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		return nil, &ValidationError{[]string{"not valid JSON: " + err.Error()}}
	}
	if err := sch.Validate(doc); err != nil {
		var ve *jsonschema.ValidationError
		if errors.As(err, &ve) {
			return nil, &ValidationError{schemaProblems(ve)}
		}
		return nil, err
	}
	var r Rules
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return nil, &ValidationError{[]string{"decoding: " + err.Error()}}
	}
	if problems := semanticProblems(&r, cat); len(problems) > 0 {
		return nil, &ValidationError{problems}
	}
	return &r, nil
}

func schemaProblems(ve *jsonschema.ValidationError) []string {
	var out []string
	var walk func(e *jsonschema.ValidationError)
	walk = func(e *jsonschema.ValidationError) {
		if len(e.Causes) == 0 {
			loc := "/" + strings.Join(e.InstanceLocation, "/")
			out = append(out, fmt.Sprintf("%s: %v", loc, e.ErrorKind))
			return
		}
		for _, c := range e.Causes {
			walk(c)
		}
	}
	walk(ve)
	return out
}

var macros = map[string]bool{"protein": true, "fat": true, "carbohydrate": true}

func semanticProblems(r *Rules, cat *Catalog) []string {
	var p []string
	seen := map[string]bool{}
	remainders := 0
	needsEnergy := ""
	for i, t := range r.Nutrients {
		at := fmt.Sprintf("nutrients[%d] (%s)", i, t.Nutrient)
		if seen[t.Nutrient] {
			p = append(p, at+": nutrient appears more than once")
		}
		seen[t.Nutrient] = true
		n, ok := cat.nutrient(t.Nutrient)
		if !ok {
			p = append(p, at+": unknown nutrient code")
			continue
		}
		switch t.Basis {
		case BasisEnergyRemainder:
			remainders++
			if !macros[t.Nutrient] {
				p = append(p, at+": energy_remainder is only for protein, fat or carbohydrate")
			}
			needsEnergy = at
		case BasisPctEnergy:
			if t.Unit != "%" {
				p = append(p, fmt.Sprintf("%s: unit must be %%, got %q", at, t.Unit))
			}
			needsEnergy = at
		default:
			if t.Unit != n.Unit {
				p = append(p, fmt.Sprintf("%s: unit must be the canonical %q, got %q", at, n.Unit, t.Unit))
			}
			if t.Basis == BasisPer1000Kcal {
				needsEnergy = at
			}
		}
		if t.Low != nil && t.High != nil && *t.Low > *t.High {
			p = append(p, at+": low is above high")
		}
		if t.Nutrient == "energy" {
			p = append(p, at+": set energy with the energy rule, not a nutrient target")
		}
	}
	if remainders > 1 {
		p = append(p, "at most one energy_remainder target")
	}
	if needsEnergy != "" && r.Energy == nil {
		p = append(p, needsEnergy+": needs an energy rule")
	}
	if r.BodyMass != nil && r.BodyMass.Basis == "measured" && r.BodyMass.ReferenceBMI != nil {
		p = append(p, "body_mass: reference_bmi only applies to basis reference_bmi")
	}
	return p
}

// CatalogPlanProblems is the extra check for Atwater's own catalog plans
// (design 0001 D3): no target may sit above a total-intake upper limit for
// any life-stage group the plan applies to. It only checks per_day targets,
// the ones comparable without a person's energy or weight.
func CatalogPlanProblems(r *Rules, cat *Catalog, authority, edition string, lifeStages []string) []string {
	var p []string
	for _, t := range r.Nutrients {
		if t.Basis != BasisPerDay {
			continue
		}
		for _, ls := range lifeStages {
			for _, v := range cat.Values {
				if v.Authority != authority || v.Edition != edition || v.LifeStage != ls || v.Nutrient != t.Nutrient ||
					v.ValueType != "UL" || v.AppliesTo != "total_intake" || v.Basis != BasisPerDay || v.High == nil {
					continue
				}
				if (t.High != nil && *t.High > *v.High) || (t.Low != nil && *t.Low > *v.High) {
					p = append(p, fmt.Sprintf("%s: target above the %s upper limit %g %s", t.Nutrient, ls, *v.High, v.Unit))
				}
			}
		}
	}
	return p
}
