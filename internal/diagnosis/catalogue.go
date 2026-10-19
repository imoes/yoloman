package diagnosis

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sync"
)

// rules.json is a copy of configs/diagnosis_rules.json, embedded so the agent binary carries its own catalogue.
// TestEmbeddedCatalogueIsTheRepoCatalogue keeps the two identical.
//
//go:embed rules.json
var rulesJSON []byte

// Rule is one entry of the catalogue.
type Rule struct {
	Order       int       `json:"order"`
	Platforms   []string  `json:"platforms"`
	Title       string    `json:"title"`
	Certainty   Certainty `json:"certainty"`
	RemedyKinds []string  `json:"remedy_kinds"`
}

// Catalogue maps rule ids to rules.
type Catalogue map[string]Rule

var (
	catOnce sync.Once
	cat     Catalogue
	catErr  error
)

// LoadCatalogue returns the embedded catalogue.
func LoadCatalogue() (Catalogue, error) {
	catOnce.Do(func() {
		var doc struct {
			Rules Catalogue `json:"rules"`
		}
		if err := json.Unmarshal(rulesJSON, &doc); err != nil {
			catErr = fmt.Errorf("diagnosis: embedded rule catalogue: %w", err)
			return
		}
		cat = doc.Rules
	})
	return cat, catErr
}

func (r Rule) appliesTo(platform string) bool {
	for _, p := range r.Platforms {
		if p == platform {
			return true
		}
	}
	return false
}

func (r Rule) offers(kind string) bool {
	for _, k := range r.RemedyKinds {
		if k == kind {
			return true
		}
	}
	return false
}
