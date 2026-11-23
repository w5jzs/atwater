package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// FDC full-download JSON shapes (Foundation, SR Legacy and Branded). Only the fields
// the importer uses are declared; everything else is ignored. Numeric-ish
// identifiers are decoded leniently because FDC is not consistent about
// quoting them across datasets and releases.

type fdcFood struct {
	FdcID           int          `json:"fdcId"`
	Description     string       `json:"description"`
	DataType        string       `json:"dataType"`
	NdbNumber       lenientStr   `json:"ndbNumber"`
	PublicationDate string       `json:"publicationDate"`
	FoodCategory    *fdcCategory `json:"foodCategory"`
	FoodNutrients   []fdcFoodNutrient
	FoodPortions    []fdcPortion
	ConvFactors     []fdcConvFactor `json:"nutrientConversionFactors"`

	// Branded only.
	BrandOwner       string   `json:"brandOwner"`
	BrandName        string   `json:"brandName"`
	GtinUpc          string   `json:"gtinUpc"`
	ServingSize      *float64 `json:"servingSize"`
	ServingSizeUnit  string   `json:"servingSizeUnit"`
	HouseholdServing string   `json:"householdServingFullText"`
	BrandedCategory  string   `json:"brandedFoodCategory"`
}

type fdcCategory struct {
	ID          int        `json:"id"`
	Code        lenientStr `json:"code"`
	Description string     `json:"description"`
}

type fdcFoodNutrient struct {
	Amount     *float64 `json:"amount"`
	Nutrient   fdcNutrient
	Derivation *struct {
		Code        string `json:"code"`
		Description string `json:"description"`
	} `json:"foodNutrientDerivation"`
}

type fdcNutrient struct {
	ID       int        `json:"id"`
	Number   lenientStr `json:"number"`
	Name     string     `json:"name"`
	UnitName string     `json:"unitName"`
}

type fdcPortion struct {
	ID                 int     `json:"id"`
	Amount             float64 `json:"amount"`
	Value              float64 `json:"value"`
	GramWeight         float64 `json:"gramWeight"`
	Modifier           string  `json:"modifier"`
	PortionDescription string  `json:"portionDescription"`
	SequenceNumber     int     `json:"sequenceNumber"`
	MeasureUnit        struct {
		Name         string `json:"name"`
		Abbreviation string `json:"abbreviation"`
	} `json:"measureUnit"`
}

type fdcConvFactor struct {
	Type              string   `json:"type"`
	Value             *float64 `json:"value"`
	ProteinValue      *float64 `json:"proteinValue"`
	FatValue          *float64 `json:"fatValue"`
	CarbohydrateValue *float64 `json:"carbohydrateValue"`
}

// lenientStr accepts a JSON string or number and keeps its text form.
type lenientStr string

func (s *lenientStr) UnmarshalJSON(b []byte) error {
	if string(b) == "null" {
		*s = ""
		return nil
	}
	if len(b) > 0 && b[0] == '"' {
		var v string
		if err := json.Unmarshal(b, &v); err != nil {
			return err
		}
		*s = lenientStr(strings.TrimSpace(v))
		return nil
	}
	*s = lenientStr(strings.TrimSpace(string(b)))
	return nil
}

// Top-level arrays in FDC full downloads, mapped to Atwater dataset codes.
var supportedRoots = map[string]string{
	"FoundationFoods": "FDC_FOUNDATION",
	"SRLegacyFoods":   "FDC_SR_LEGACY",
	"BrandedFoods":    "FDC_BRANDED",
}

// foodStream walks {"<Root>": [ food, food, ... ]} one food at a time, so a
// several-hundred-MB download never has to fit in memory.
type foodStream struct {
	dec         *json.Decoder
	DatasetCode string
	Root        string
}

func openFoodStream(r io.Reader) (*foodStream, error) {
	dec := json.NewDecoder(r)
	dec.UseNumber()
	if err := expectDelim(dec, '{'); err != nil {
		return nil, err
	}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, _ := tok.(string)
		if code, ok := supportedRoots[key]; ok {
			if err := expectDelim(dec, '['); err != nil {
				return nil, fmt.Errorf("%s: %w", key, err)
			}
			return &foodStream{dec: dec, DatasetCode: code, Root: key}, nil
		}
		// Skip any other top-level value.
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			return nil, err
		}
		if strings.HasSuffix(key, "Foods") {
			return nil, fmt.Errorf("dataset %q is not supported yet (supported: FoundationFoods, SRLegacyFoods, BrandedFoods)", key)
		}
	}
	return nil, fmt.Errorf("no FoundationFoods, SRLegacyFoods or BrandedFoods array found; is this an FDC full-download JSON file?")
}

// Next returns the next food, or (nil, io.EOF) at the end of the array.
func (s *foodStream) Next() (*fdcFood, error) {
	if !s.dec.More() {
		return nil, io.EOF
	}
	var f fdcFood
	if err := s.dec.Decode(&f); err != nil {
		return nil, err
	}
	return &f, nil
}

func expectDelim(dec *json.Decoder, want json.Delim) error {
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if d, ok := tok.(json.Delim); !ok || d != want {
		return fmt.Errorf("expected %q, got %v", want, tok)
	}
	return nil
}
