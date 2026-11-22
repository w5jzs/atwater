package targets

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/golden from the current resolver")

func TestCanonical(t *testing.T) {
	type s struct {
		Zeta  string  `json:"zeta"`
		Alpha float64 `json:"alpha"`
		Mid   []int   `json:"mid"`
	}
	b, err := Canonical(s{"a<b&c", 0.1, []int{3, 1}})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"alpha":0.1,"mid":[3,1],"zeta":"a<b&c"}`; string(b) != want {
		t.Fatalf("got  %s\nwant %s", b, want)
	}
}

// Days with the same effective inputs share one resolution (D5, D8): a
// day later, with the trend weight moving less than 0.5 kg, hashes the
// same; a real move, or a new resolver version, doesn't.
func TestInputsHashReuse(t *testing.T) {
	cat := resolverCatalog(t)
	day1 := man40()
	day1.Plan = d1Plan(t, -500)
	day2 := day1
	day2.Date = "2026-11-23"
	day2.BodyMass = append(append([]Reading{}, day1.BodyMass...), Reading{"2026-11-23", 105.1})

	r1, err := Resolve(day1, cat)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := Resolve(day2, cat)
	if err != nil {
		t.Fatal(err)
	}
	if r1.InputsHash != r2.InputsHash {
		t.Fatalf("same effective inputs, different hashes:\n%s\n%s", r1.InputsJSON, r2.InputsJSON)
	}
	day2.BodyMass = []Reading{{"2026-11-23", 103.5}}
	r3, _ := Resolve(day2, cat)
	if r3.InputsHash == r1.InputsHash {
		t.Fatal("a 1.5 kg trend move should change the hash")
	}
	var in ResolvedInputs
	_ = json.Unmarshal(r1.InputsJSON, &in)
	in.ResolverVersion++
	_, h, _ := HashInputs(in)
	if h == r1.InputsHash {
		t.Fatal("a new resolver version should change the hash")
	}
}

type golden struct {
	Targets      []Target        `json:"targets"`
	Warnings     []Warning       `json:"warnings"`
	Inputs       json.RawMessage `json:"inputs"`
	InputsSHA256 string          `json:"inputs_sha256"`
}

// Golden scenarios: the full output for representative people, checked in so
// any change in what the resolver produces shows up in review. Regenerate
// with `go test -run TestGolden -update` and read the diff.
func TestGolden(t *testing.T) {
	scenarios := map[string]func() Inputs{
		"worked_example": func() Inputs { in := man40(); in.Plan = d1Plan(t, -500); return in },
		"authority_only": man40,
		"missing_activity_level": func() Inputs {
			in := man40()
			in.Person.ActivityLevel = ""
			in.Plan = d1Plan(t, -500)
			return in
		},
		"pregnancy": func() Inputs {
			return Inputs{Date: "2026-11-22", Person: Person{BirthDate: "1990-01-01", ReferenceSex: "female",
				HeightCM: f(165), ActivityLevel: "active", PhysiologicalState: "pregnant"},
				BodyMass: []Reading{{"2026-11-22", 70}}}
		},
		"infant": func() Inputs {
			return Inputs{Date: "2026-11-22", Person: Person{BirthDate: "2026-08-01", ReferenceSex: "female"}}
		},
		"overrides_far_from_recommended": func() Inputs {
			in := man40()
			in.Plan = d1Plan(t, -500)
			in.Overrides = []Override{
				{ID: "o-vitd", Version: 3, NutrientID: 202, Basis: BasisPerDay, Low: f(125), SetBy: "clinician", ValidFrom: "2026-01-01"},
				{ID: "o-vitc", Version: 1, NutrientID: 201, Basis: BasisPerDay, Low: f(60), SetBy: "user", ValidFrom: "2026-11-01"},
				{ID: "o-kcal", Version: 2, NutrientID: 1, Basis: BasisPerDay, Low: f(1800), SetBy: "user", ValidFrom: "2026-11-01"},
			}
			return in
		},
	}
	cat := resolverCatalog(t)
	for name, build := range scenarios {
		t.Run(name, func(t *testing.T) {
			res, err := Resolve(build(), cat)
			if err != nil {
				t.Fatal(err)
			}
			g := golden{Targets: res.Targets, Warnings: res.Warnings, Inputs: res.InputsJSON,
				InputsSHA256: hex.EncodeToString(res.InputsHash[:])}
			if g.Warnings == nil {
				g.Warnings = []Warning{}
			}
			got, err := json.MarshalIndent(g, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			got = append(got, '\n')
			path := filepath.Join("testdata", "golden", name+".json")
			if *update {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, got, 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("%v (run with -update to create it)", err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("output differs from %s; if the change is intended, rerun with -update and review the diff.\ngot:\n%s", path, got)
			}
		})
	}
}
