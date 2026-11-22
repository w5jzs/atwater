package targets

import (
	"fmt"
	"math"
	"sort"
	"time"
)

// ResolverVersion is recorded in every resolution's inputs (D8). Bump it when
// the algorithm changes so new resolutions hash differently and history stays.
const ResolverVersion = 1

// Defaults from design 0001; recorded in the inputs so they can be tuned.
const (
	DefaultAuthority          = "NASEM_DRI"
	DefaultDRIEdition         = "consolidated-2019"
	DefaultEnergyEdition      = "2023-energy"
	energyWarnFraction        = 0.25 // D4
	trendDays                 = 7    // D5
	staleDays                 = 90   // D5
	bodyMassStepKG            = 0.5  // D5
	defaultReferenceBMI       = 25.0 // D5
	dayLayout                 = "2006-01-02"
	SourceAuthority           = "authority"
	SourcePlan                = "plan"
	SourcePlanRemainder       = "plan_remainder"
	SourceUser                = "user"
	SourceClinician           = "clinician"
	WarnExceedsUpperLimit     = "exceeds_upper_limit"
	WarnBelowRecommended      = "below_recommended"
	WarnEnergyFarFromEstimate = "energy_far_from_estimate"
	WarnStaleBodyMass         = "stale_body_mass"
	WarnNoLifeStageGroup      = "no_life_stage_group"
	WarnUnresolvedNutrient    = "unresolved_nutrient"
	WarnRemainderInfeasible   = "energy_remainder_infeasible"
)

// General Atwater factors, kcal/g, for converting energy-based targets (D9).
var kcalPerGram = map[string]float64{
	"protein": 4, "carbohydrate": 4, "sugars": 4, "added_sugars": 4,
	"fat": 9, "sat_fat": 9, "mufa": 9, "pufa": 9, "trans_fat": 9, "alcohol": 7,
}

// Inputs is everything one resolution depends on, for one user and local date.
type Inputs struct {
	Date          string // local date, YYYY-MM-DD
	Authority     string // default NASEM_DRI
	DRIEdition    string // default consolidated-2019
	EnergyEdition string // default 2023-energy
	Person        Person
	BodyMass      []Reading // body_mass readings; the resolver picks the window
	Plan          *Plan
	Overrides     []Override // all of the user's overrides; the resolver filters by date
}

type Person struct {
	BirthDate          string   // YYYY-MM-DD
	ReferenceSex       string   // female | male
	HeightCM           *float64 // usr.account.height_cm
	ActivityLevel      string   // usr.account.activity_level; "" = unknown
	PhysiologicalState string   // none | pregnant | lactating on Date
}

type Reading struct {
	Date string  // local date of the reading
	KG   float64 // value_canonical
}

type Plan struct {
	VersionID          string // ref.diet_plan_version or usr.custom_plan_version id
	RulesSchemaVersion int
	Rules              *Rules
	EnergyAdjustKcal   int // usr.plan_assignment.energy_adjust_kcal
}

type Override struct {
	ID         string
	Version    int
	NutrientID int16
	Basis      string
	Low, High  *float64
	SetBy      string // user | clinician
	ValidFrom  string // inclusive
	ValidTo    string // exclusive; "" = open-ended
}

// Target is one usr.daily_target row: per day, in the nutrient's canonical unit.
type Target struct {
	NutrientID int16    `json:"nutrient_id"`
	Nutrient   string   `json:"nutrient"`
	Low        *float64 `json:"target_low,omitempty"`
	High       *float64 `json:"target_high,omitempty"`
	UpperLimit *float64 `json:"upper_limit,omitempty"`
	Source     string   `json:"source,omitempty"`
}

// Warning is one entry of usr.target_resolution.warnings (D3, D8).
type Warning struct {
	Code     string         `json:"code"`
	Nutrient string         `json:"nutrient,omitempty"`
	Detail   map[string]any `json:"detail,omitempty"`
}

type Result struct {
	Targets  []Target
	Warnings []Warning
	Inputs   ResolvedInputs // provenance (D8)
}

// ResolvedInputs is what the resolver actually used: the content of
// usr.target_resolution.inputs. Two days with equal ResolvedInputs get the
// same targets, so they share one resolution.
type ResolvedInputs struct {
	ResolverVersion int             `json:"resolver_version"`
	Authority       string          `json:"authority"`
	DRIEdition      string          `json:"dri_edition"`
	LifeStage       string          `json:"life_stage,omitempty"`
	Energy          *EnergyInputs   `json:"energy,omitempty"`
	BodyMass        *BodyMassInputs `json:"body_mass,omitempty"`
	Plan            *PlanInputs     `json:"plan,omitempty"`
	Overrides       []OverrideRef   `json:"overrides,omitempty"`
	Config          ConfigInputs    `json:"config"`
}

type EnergyInputs struct {
	Method        string   `json:"method"`
	Edition       string   `json:"edition,omitempty"`
	LifeStage     string   `json:"life_stage,omitempty"`
	ActivityLevel string   `json:"activity_level,omitempty"`
	AgeYears      *int     `json:"age_years,omitempty"`
	HeightCM      *float64 `json:"height_cm,omitempty"`
	EstimateKcal  *float64 `json:"estimate_kcal,omitempty"`
	AdjustKcal    int      `json:"adjust_kcal,omitempty"`
	TargetKcal    *float64 `json:"target_kcal,omitempty"`
	OverrideID    string   `json:"override_id,omitempty"`
}

type BodyMassInputs struct {
	MeasuredKG   float64  `json:"measured_kg"` // trend, rounded to 0.5 kg
	Stale        bool     `json:"stale,omitempty"`
	Basis        string   `json:"basis"` // what per-kg nutrient targets use
	ReferenceBMI *float64 `json:"reference_bmi,omitempty"`
	ReferenceKG  *float64 `json:"reference_kg,omitempty"`
}

type PlanInputs struct {
	VersionID          string `json:"version_id"`
	RulesSchemaVersion int    `json:"rules_schema_version"`
}

type OverrideRef struct {
	ID      string `json:"id"`
	Version int    `json:"version"`
}

type ConfigInputs struct {
	EnergyWarnFraction float64 `json:"energy_warn_fraction"`
	TrendDays          int     `json:"trend_days"`
	StaleDays          int     `json:"stale_days"`
	BodyMassStepKG     float64 `json:"body_mass_step_kg"`
}

// span is a resolved per-day range plus where it came from.
type span struct {
	low, high *float64
	source    string
}

type resolver struct {
	in       Inputs
	cat      *Catalog
	day      time.Time
	res      *Result
	measured *float64 // trend body mass, kg
	perKgKG  *float64 // body mass per-kg nutrient targets use
	energy   *float64 // the day's energy target, kcal
	eer      *float64
	ranges   map[string]span
	upper    map[string]float64
	rec      map[string]float64 // authority RDA/AI per day, for below_recommended
}

func (r *resolver) warn(code, nutrient string, detail map[string]any) {
	r.res.Warnings = append(r.res.Warnings, Warning{Code: code, Nutrient: nutrient, Detail: detail})
}

// Resolve computes one day's targets. It returns an error only for malformed
// inputs; missing data (no weight, no activity level, no matching group) is
// reported as warnings and the affected targets are left out.
func Resolve(in Inputs, cat *Catalog) (*Result, error) {
	if in.Authority == "" {
		in.Authority = DefaultAuthority
	}
	if in.DRIEdition == "" {
		in.DRIEdition = DefaultDRIEdition
	}
	if in.EnergyEdition == "" {
		in.EnergyEdition = DefaultEnergyEdition
	}
	if in.Person.PhysiologicalState == "" {
		in.Person.PhysiologicalState = "none"
	}
	day, err := time.Parse(dayLayout, in.Date)
	if err != nil {
		return nil, fmt.Errorf("date: %w", err)
	}
	if cat.byCode == nil {
		if err := cat.Index(); err != nil {
			return nil, err
		}
	}
	r := &resolver{in: in, cat: cat, day: day, res: &Result{}, ranges: map[string]span{},
		upper: map[string]float64{}, rec: map[string]float64{}}
	r.res.Inputs = ResolvedInputs{
		ResolverVersion: ResolverVersion, Authority: in.Authority, DRIEdition: in.DRIEdition,
		Config: ConfigInputs{energyWarnFraction, trendDays, staleDays, bodyMassStepKG},
	}
	if in.Plan != nil {
		if in.Plan.Rules == nil {
			return nil, fmt.Errorf("plan %s has no rules", in.Plan.VersionID)
		}
		r.res.Inputs.Plan = &PlanInputs{in.Plan.VersionID, in.Plan.RulesSchemaVersion}
	}

	ageMonths, err := r.ageMonths()
	if err != nil {
		return nil, err
	}
	overrides, err := r.activeOverrides()
	if err != nil {
		return nil, err
	}
	if err := r.bodyMass(); err != nil {
		return nil, err
	}
	r.resolveEnergy(ageMonths, overrides)
	group := r.driGroup(ageMonths)
	if group != "" {
		r.authorityLayer(group)
	}
	if in.Plan != nil {
		r.planLayer()
	}
	for _, setBy := range []string{"user", "clinician"} { // clinician beats user (D2)
		for _, o := range overrides {
			if o.SetBy == setBy {
				r.overrideLayer(o)
			}
		}
	}
	r.remainder()
	r.finish()
	return r.res, nil
}

func (r *resolver) ageMonths() (int, error) {
	if r.in.Person.BirthDate == "" {
		return -1, nil
	}
	b, err := time.Parse(dayLayout, r.in.Person.BirthDate)
	if err != nil {
		return 0, fmt.Errorf("birth date: %w", err)
	}
	m := (r.day.Year()-b.Year())*12 + int(r.day.Month()-b.Month())
	if r.day.Day() < b.Day() {
		m--
	}
	if m < 0 {
		return 0, fmt.Errorf("birth date %s is after %s", r.in.Person.BirthDate, r.in.Date)
	}
	return m, nil
}

func (r *resolver) activeOverrides() ([]Override, error) {
	var out []Override
	for _, o := range r.in.Overrides {
		from, err := time.Parse(dayLayout, o.ValidFrom)
		if err != nil {
			return nil, fmt.Errorf("override %s valid_from: %w", o.ID, err)
		}
		if r.day.Before(from) {
			continue
		}
		if o.ValidTo != "" {
			to, err := time.Parse(dayLayout, o.ValidTo)
			if err != nil {
				return nil, fmt.Errorf("override %s valid_to: %w", o.ID, err)
			}
			if !r.day.Before(to) {
				continue
			}
		}
		if _, ok := r.cat.nutrientByID(o.NutrientID); !ok {
			return nil, fmt.Errorf("override %s: unknown nutrient id %d", o.ID, o.NutrientID)
		}
		if o.SetBy != "user" && o.SetBy != "clinician" {
			return nil, fmt.Errorf("override %s: set_by %q", o.ID, o.SetBy)
		}
		out = append(out, o)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	for _, o := range out {
		r.res.Inputs.Overrides = append(r.res.Inputs.Overrides, OverrideRef{o.ID, o.Version})
	}
	return out, nil
}

// bodyMass: 7-day mean up to and including the date; else the latest reading
// up to 90 days old (stale); else none. Rounded to 0.5 kg (D5).
func (r *resolver) bodyMass() error {
	var window []float64
	var latest *Reading
	var latestDay time.Time
	for i := range r.in.BodyMass {
		rd := r.in.BodyMass[i]
		d, err := time.Parse(dayLayout, rd.Date)
		if err != nil {
			return fmt.Errorf("body mass reading date: %w", err)
		}
		age := int(r.day.Sub(d).Hours() / 24)
		if age < 0 || age >= staleDays {
			continue
		}
		if age < trendDays {
			window = append(window, rd.KG)
		}
		if latest == nil || d.After(latestDay) {
			latest, latestDay = &r.in.BodyMass[i], d
		}
	}
	var kg float64
	stale := false
	switch {
	case len(window) > 0:
		for _, v := range window {
			kg += v
		}
		kg /= float64(len(window))
	case latest != nil:
		kg, stale = latest.KG, true
		r.warn(WarnStaleBodyMass, "", map[string]any{"age_days": int(r.day.Sub(latestDay).Hours() / 24)})
	default:
		return nil
	}
	kg = math.Round(kg/bodyMassStepKG) * bodyMassStepKG
	r.measured = &kg
	bm := &BodyMassInputs{MeasuredKG: kg, Stale: stale, Basis: "measured"}
	r.perKgKG = &kg
	if r.in.Plan != nil {
		if basis, bmi := r.in.Plan.Rules.bodyMassBasis(); basis == "reference_bmi" {
			bm.Basis, bm.ReferenceBMI = basis, f(bmi)
			if h := r.in.Person.HeightCM; h != nil {
				ref := round6(bmi * (*h / 100) * (*h / 100))
				bm.ReferenceKG, r.perKgKG = &ref, &ref
			} else {
				r.perKgKG = nil // can't compute a reference weight without height
			}
		}
	}
	r.res.Inputs.BodyMass = bm
	return nil
}

// findGroup picks the one life-stage group of the authority matching the
// person, among groups that `has` accepts. Sex-specific groups win over 'any'.
func (r *resolver) findGroup(ageMonths int, state string, has func(code string) bool) (string, error) {
	if ageMonths < 0 {
		return "", nil
	}
	for _, sex := range []string{r.in.Person.ReferenceSex, "any"} {
		var hits []string
		for _, g := range r.cat.LifeStages {
			if g.Authority != r.in.Authority || g.Sex != sex || g.PhysiologicalState != state || !has(g.Code) {
				continue
			}
			if ageMonths >= g.AgeMinMonths && (g.AgeMaxMonths == nil || ageMonths < *g.AgeMaxMonths) {
				hits = append(hits, g.Code)
			}
		}
		if len(hits) > 1 {
			sort.Strings(hits)
			return "", fmt.Errorf("catalog: %d life-stage groups match (%v)", len(hits), hits)
		}
		if len(hits) == 1 {
			return hits[0], nil
		}
	}
	return "", nil
}

func (r *resolver) driGroup(ageMonths int) string {
	has := map[string]bool{}
	for _, v := range r.cat.Values {
		if v.Authority == r.in.Authority && v.Edition == r.in.DRIEdition {
			has[v.LifeStage] = true
		}
	}
	g, err := r.findGroup(ageMonths, r.in.Person.PhysiologicalState, func(c string) bool { return has[c] })
	if err == nil && g != "" {
		r.res.Inputs.LifeStage = g
		return g
	}
	detail := map[string]any{}
	if err != nil {
		detail["error"] = err.Error()
	}
	if ageMonths < 0 {
		detail["missing"] = "birth_date"
	}
	if r.in.Person.ReferenceSex == "" {
		detail["missing_sex"] = true
	}
	r.warn(WarnNoLifeStageGroup, "", detail)
	return ""
}

func (r *resolver) resolveEnergy(ageMonths int, overrides []Override) {
	method := "eer"
	if r.in.Plan != nil && r.in.Plan.Rules.Energy != nil {
		method = r.in.Plan.Rules.Energy.Method
	}
	ei := &EnergyInputs{Method: method, Edition: r.in.EnergyEdition}
	r.res.Inputs.Energy = ei

	// The estimate is always computed when possible: eer plans use it, and
	// fixed plans and overrides are compared against it (D4).
	r.eer = r.estimate(ageMonths, ei, method == "eer")
	switch method {
	case "eer":
		if r.eer != nil {
			adj := 0
			if r.in.Plan != nil {
				adj = r.in.Plan.EnergyAdjustKcal
			}
			ei.AdjustKcal = adj
			t := math.Round(*r.eer + float64(adj))
			r.energy = &t
		}
	case "fixed":
		t := *r.in.Plan.Rules.Energy.Kcal
		r.energy = &t
	}
	src := SourceAuthority
	if r.in.Plan != nil {
		src = SourcePlan
	}
	// An energy override replaces the target (clinician beats user).
	for _, setBy := range []string{"user", "clinician"} {
		for _, o := range overrides {
			n, _ := r.cat.nutrientByID(o.NutrientID)
			if n.Code != "energy" || o.SetBy != setBy {
				continue
			}
			if o.Basis != BasisPerDay || (o.Low == nil && o.High == nil) {
				r.warn(WarnUnresolvedNutrient, "energy", map[string]any{"reason": "energy overrides must be per_day", "override": o.ID})
				continue
			}
			v := o.Low
			if v == nil {
				v = o.High
			}
			t := *v
			r.energy, src, ei.OverrideID = &t, setBy, o.ID
		}
	}
	if r.energy == nil {
		r.warn(WarnUnresolvedNutrient, "energy", map[string]any{"reason": "no energy estimate"})
		return
	}
	ei.TargetKcal = r.energy
	r.ranges["energy"] = span{r.energy, r.energy, src}
	if r.eer != nil && math.Abs(*r.energy-*r.eer) > energyWarnFraction**r.eer {
		r.warn(WarnEnergyFarFromEstimate, "energy", map[string]any{"estimate_kcal": *r.eer, "target_kcal": *r.energy})
	}
}

func (r *resolver) estimate(ageMonths int, ei *EnergyInputs, needed bool) *float64 {
	miss := func(what string) *float64 {
		if needed {
			r.warn(WarnUnresolvedNutrient, "energy", map[string]any{"reason": "estimate needs " + what})
		}
		return nil
	}
	p := r.in.Person
	if ageMonths < 0 {
		return miss("birth_date")
	}
	if p.ActivityLevel == "" {
		return miss("activity_level")
	}
	if p.HeightCM == nil {
		return miss("height")
	}
	if r.measured == nil {
		return miss("body_mass")
	}
	var eqs []EnergyEquation
	has := map[string]bool{}
	for _, e := range r.cat.EnergyEquations {
		if e.Authority == r.in.Authority && e.Edition == r.in.EnergyEdition && e.ActivityLevel == p.ActivityLevel {
			eqs = append(eqs, e)
			has[e.LifeStage] = true
		}
	}
	// Equations are for the person's actual state; pregnancy and lactation
	// equations aren't loaded, so those states get no estimate.
	g, err := r.findGroup(ageMonths, p.PhysiologicalState, func(c string) bool { return has[c] })
	if err != nil || g == "" {
		return miss("an energy equation for this life stage")
	}
	for _, e := range eqs {
		if e.LifeStage != g {
			continue
		}
		years := ageMonths / 12 // whole years (catalog 0007)
		v := e.Intercept + e.AgeYears*float64(years) + e.HeightCM**p.HeightCM + e.WeightKG**r.measured + e.Extra
		v = math.Round(v*100) / 100
		ei.LifeStage, ei.ActivityLevel, ei.AgeYears, ei.HeightCM, ei.EstimateKcal = g, p.ActivityLevel, &years, p.HeightCM, &v
		return &v
	}
	return miss("an energy equation for this life stage")
}

// toPerDay converts an amount on any basis to a per-day amount in the
// nutrient's canonical unit (D9). ok=false: inputs needed for it are missing.
func (r *resolver) toPerDay(nutrient, basis string, amount float64, perKg *float64) (float64, bool) {
	switch basis {
	case BasisPerDay:
		return amount, true
	case BasisPerKg:
		if perKg == nil {
			return 0, false
		}
		return amount * *perKg, true
	case BasisPer1000Kcal:
		if r.energy == nil {
			return 0, false
		}
		return amount * *r.energy / 1000, true
	case BasisPctEnergy:
		k, ok := kcalPerGram[nutrient]
		if r.energy == nil || !ok {
			return 0, false
		}
		return amount / 100 * *r.energy / k, true
	}
	return 0, false
}

// authorityLayer: RDA/AI (per kg when a body mass is known, else per day) and
// AMDR lows give the low; AMDR, CDRR and DG highs give the high; the highest
// low and lowest high win. A total-intake UL is the upper limit (D2).
func (r *resolver) authorityLayer(group string) {
	type acc struct {
		lows, highs      []float64
		recPerKg, recDay *float64
	}
	by := map[string]*acc{}
	get := func(n string) *acc {
		if by[n] == nil {
			by[n] = &acc{}
		}
		return by[n]
	}
	for _, v := range r.cat.Values {
		if v.Authority != r.in.Authority || v.Edition != r.in.DRIEdition || v.LifeStage != group {
			continue
		}
		if _, ok := r.cat.nutrient(v.Nutrient); !ok {
			continue
		}
		a := get(v.Nutrient)
		switch v.ValueType {
		case "RDA", "AI":
			if v.Low == nil {
				continue
			}
			// Per-kg values follow the plan's body-mass basis, like plan targets (D5).
			if amt, ok := r.toPerDay(v.Nutrient, v.Basis, *v.Low, r.perKgKG); ok {
				if v.Basis == BasisPerKg {
					a.recPerKg = &amt
				} else if v.Basis == BasisPerDay {
					a.recDay = &amt
				}
			}
		case "AMDR":
			if v.Low != nil {
				if amt, ok := r.toPerDay(v.Nutrient, v.Basis, *v.Low, r.measured); ok {
					a.lows = append(a.lows, amt)
				}
			}
			if v.High != nil {
				if amt, ok := r.toPerDay(v.Nutrient, v.Basis, *v.High, r.measured); ok {
					a.highs = append(a.highs, amt)
				}
			}
		case "CDRR", "DG":
			if v.High != nil {
				if amt, ok := r.toPerDay(v.Nutrient, v.Basis, *v.High, r.measured); ok {
					a.highs = append(a.highs, amt)
				}
			}
		case "UL":
			if v.AppliesTo == "total_intake" && v.Basis == BasisPerDay && v.High != nil {
				r.upper[v.Nutrient] = *v.High
			}
		}
	}
	for n, a := range by {
		rec := a.recDay
		if a.recPerKg != nil { // D6: per-kg when a body mass is known
			rec = a.recPerKg
		}
		if rec != nil {
			r.rec[n] = *rec
			a.lows = append(a.lows, *rec)
		}
		var s span
		s.source = SourceAuthority
		for _, l := range a.lows {
			if s.low == nil || l > *s.low {
				s.low = f(l)
			}
		}
		for _, h := range a.highs {
			if s.high == nil || h < *s.high {
				s.high = f(h)
			}
		}
		if (s.low != nil || s.high != nil) && n != "energy" {
			r.ranges[n] = s
		}
	}
}

func (r *resolver) planLayer() {
	rules := r.in.Plan.Rules
	if !rules.inheritsAuthority() {
		for n, s := range r.ranges {
			if n != "energy" && s.source == SourceAuthority {
				delete(r.ranges, n)
			}
		}
	}
	for _, t := range rules.Nutrients {
		if t.Basis == BasisEnergyRemainder {
			continue // after every other layer (remainder)
		}
		r.setRange(t.Nutrient, t.Basis, t.Low, t.High, r.perKgKG, SourcePlan, "")
	}
}

func (r *resolver) overrideLayer(o Override) {
	n, _ := r.cat.nutrientByID(o.NutrientID)
	if n.Code == "energy" {
		return // handled in resolveEnergy
	}
	// Overrides are per the person's own measured weight, not a plan's reference weight.
	r.setRange(n.Code, o.Basis, o.Low, o.High, r.measured, o.SetBy, o.ID)
}

// setRange replaces a nutrient's whole range (D2). If the range can't be
// resolved, the nutrient is left without a target and a warning says why.
func (r *resolver) setRange(nutrient, basis string, low, high, perKg *float64, source, overrideID string) {
	var s span
	s.source = source
	for _, p := range []struct {
		in  *float64
		out **float64
	}{{low, &s.low}, {high, &s.high}} {
		if p.in == nil {
			continue
		}
		amt, ok := r.toPerDay(nutrient, basis, *p.in, perKg)
		if !ok {
			d := map[string]any{"reason": "can't convert " + basis, "source": source}
			if overrideID != "" {
				d["override"] = overrideID
			}
			r.warn(WarnUnresolvedNutrient, nutrient, d)
			delete(r.ranges, nutrient)
			return
		}
		*p.out = f(amt)
	}
	r.ranges[nutrient] = s
}

// remainder fills a plan's energy_remainder macro from the energy left after
// the other two macros. Bounds invert: its high comes from their lows, its
// low from their highs (D9). An override on the macro itself wins.
func (r *resolver) remainder() {
	if r.in.Plan == nil {
		return
	}
	var rem string
	for _, t := range r.in.Plan.Rules.Nutrients {
		if t.Basis == BasisEnergyRemainder {
			rem = t.Nutrient
		}
	}
	if rem == "" {
		return
	}
	if s, ok := r.ranges[rem]; ok && (s.source == SourceUser || s.source == SourceClinician) {
		return
	}
	if r.energy == nil {
		r.warn(WarnUnresolvedNutrient, rem, map[string]any{"reason": "energy_remainder needs an energy target"})
		delete(r.ranges, rem)
		return
	}
	minUsed, maxUsed, maxKnown := 0.0, 0.0, true
	for m := range macros {
		if m == rem {
			continue
		}
		s := r.ranges[m]
		if s.low != nil {
			minUsed += *s.low * kcalPerGram[m]
		}
		if s.high != nil {
			maxUsed += *s.high * kcalPerGram[m]
		} else {
			maxKnown = false
		}
	}
	k := kcalPerGram[rem]
	hi := (*r.energy - minUsed) / k
	if hi < 0 {
		r.warn(WarnRemainderInfeasible, rem, map[string]any{"energy_kcal": *r.energy, "other_macros_min_kcal": minUsed})
		delete(r.ranges, rem)
		return
	}
	s := span{high: f(hi), source: SourcePlanRemainder}
	if maxKnown {
		if lo := (*r.energy - maxUsed) / k; lo > 0 {
			s.low = f(lo)
		}
	}
	r.ranges[rem] = s
}

func (r *resolver) finish() {
	names := map[string]bool{}
	for n := range r.ranges {
		names[n] = true
	}
	for n := range r.upper {
		names[n] = true
	}
	for n := range names {
		nut, _ := r.cat.nutrient(n)
		s := r.ranges[n]
		t := Target{NutrientID: nut.ID, Nutrient: n, Low: round6p(s.low), High: round6p(s.high), Source: s.source}
		if ul, ok := r.upper[n]; ok {
			t.UpperLimit = f(round6(ul))
			if (t.High != nil && *t.High > ul) || (t.Low != nil && *t.Low > ul) {
				r.warn(WarnExceedsUpperLimit, n, map[string]any{"upper_limit": ul})
			}
		}
		if rec, ok := r.rec[n]; ok && s.source != SourceAuthority && s.source != "" {
			if (t.Low != nil && *t.Low < rec) || (t.Low == nil && t.High != nil && *t.High < rec) {
				r.warn(WarnBelowRecommended, n, map[string]any{"recommended": round6(rec)})
			}
		}
		r.res.Targets = append(r.res.Targets, t)
	}
	sort.Slice(r.res.Targets, func(i, j int) bool { return r.res.Targets[i].NutrientID < r.res.Targets[j].NutrientID })
	sort.SliceStable(r.res.Warnings, func(i, j int) bool {
		a, b := r.res.Warnings[i], r.res.Warnings[j]
		if a.Code != b.Code {
			return a.Code < b.Code
		}
		return a.Nutrient < b.Nutrient
	})
}

func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }

func round6p(p *float64) *float64 {
	if p == nil {
		return nil
	}
	return f(round6(*p))
}

func f(v float64) *float64 { return &v }
