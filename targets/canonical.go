package targets

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
)

// Canonical serializes v the way usr.target_resolution.inputs is hashed
// (D8): object keys sorted lexicographically, no insignificant whitespace,
// no HTML escaping, numbers in ES6 form (Go's encoding/json already formats
// floats that way). This matches RFC 8785 for the inputs the resolver
// records: ASCII identifiers and ordinary numbers.
func Canonical(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	// Round-trip through generic values so struct field order becomes sorted
	// map keys; UseNumber keeps each number's text exactly as marshalled.
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var generic any
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n")), nil
}

// HashInputs returns the canonical inputs and their SHA-256, the values for
// target_resolution.inputs and inputs_hash. Equal hashes mean the same
// targets, so a day can reuse an existing resolution.
func HashInputs(in ResolvedInputs) ([]byte, [32]byte, error) {
	b, err := Canonical(in)
	if err != nil {
		return nil, [32]byte{}, err
	}
	return b, sha256.Sum256(b), nil
}
