// Package diagnosis is the explainable diagnosis: why does a target on this host not work?
//
// The agent collects EVIDENCE — single measurements with a stable id — and RULES turn evidence into FINDINGS with a
// certainty. Nothing here guesses: a finding cites the evidence it rests on, an Unknown names what could not be
// measured, a target that is not running always has a finding. The wire format is the shared contract
// configs/schemas/diagnosis.schema.json (the Windows agent emits the same documents; Bossman checks them again on
// ingest). Prose: docs/diagnosis.md.
package diagnosis

import (
	"fmt"
	"strings"
	"time"
	"unicode"
)

// SchemaID names the contract version a document follows.
const SchemaID = "yoloman.diagnosis/v1"

// Certainty of a finding.
type Certainty string

const (
	// Proven — measured directly (an exit code, a missing file, a right that is not granted).
	Proven Certainty = "Proven"
	// Likely — inferred from several measurements, or from log text.
	Likely Certainty = "Likely"
	// Unknown — the cause cannot be determined; the finding names the gap.
	Unknown Certainty = "Unknown"
)

var certaintyRank = map[Certainty]int{Unknown: 0, Likely: 1, Proven: 2}

// Status of the target when it was collected. "unknown" is a named state (the agent could not read it).
const (
	StatusRunning  = "running"
	StatusStopped  = "stopped"
	StatusFailed   = "failed"
	StatusStarting = "starting"
	StatusNotFound = "not-found"
	StatusUnknown  = "unknown"
	// The updates target's states: up-to-date (nothing pending) or behind (updates pending / a failure).
	StatusUpToDate = "up-to-date"
	StatusBehind   = "behind"
)

// Target is what the diagnosis is about.
type Target struct {
	Kind        string  `json:"kind"`
	Name        string  `json:"name"`
	DisplayName *string `json:"display_name"`
}

// Evidence is one measurement.
type Evidence struct {
	ID       string     `json:"id"`
	Source   string     `json:"source"`
	Observed *time.Time `json:"observed"`
	Fact     string     `json:"fact"`
	Raw      any        `json:"raw"`
}

// Precedent is the most recent change before the first failure — a correlation, never a cause.
type Precedent struct {
	EvidenceID string    `json:"evidence_id"`
	Change     string    `json:"change"`
	Observed   time.Time `json:"observed"`
	GapSeconds int64     `json:"gap_seconds"`
}

// RemedyTarget is what a remedy addresses.
type RemedyTarget struct {
	Kind      string  `json:"kind"`
	ID        string  `json:"id"`
	Attribute *string `json:"attribute"`
}

// Rollback undoes a remedy.
type Rollback struct {
	Action string `json:"action"`
	Value  any    `json:"value"`
}

// Verify says how to tell a remedy worked.
type Verify struct {
	RuleAbsent string `json:"rule_absent"`
	Expect     any    `json:"expect"`
}

// Remedy is a repair as data — exported and proposed by Bossman, never executed by the agent.
type Remedy struct {
	Action   string       `json:"action"`
	Target   RemedyTarget `json:"target"`
	Before   any          `json:"before"`
	After    any          `json:"after"`
	Rollback Rollback     `json:"rollback"`
	Verify   Verify       `json:"verify"`
}

// Finding is a claim about a cause, made by a rule.
type Finding struct {
	RuleID      string     `json:"rule_id"`
	Claim       string     `json:"claim"`
	Certainty   Certainty  `json:"certainty"`
	EvidenceIDs []string   `json:"evidence_ids"`
	Precedent   *Precedent `json:"precedent"`
	Remedy      *Remedy    `json:"remedy"`
	Gap         *string    `json:"gap"`
}

// TimelineEntry places one evidence in time.
type TimelineEntry struct {
	Observed   time.Time `json:"observed"`
	EvidenceID string    `json:"evidence_id"`
}

// Gap is something the agent could not observe at all.
type Gap struct {
	What string `json:"what"`
	Why  string `json:"why"`
}

// Diagnosis is the whole document.
type Diagnosis struct {
	Schema      string          `json:"schema"`
	DiagnosisID string          `json:"diagnosis_id"`
	Host        string          `json:"host"`
	Platform    string          `json:"platform"`
	Target      Target          `json:"target"`
	CollectedAt time.Time       `json:"collected_at"`
	Status      string          `json:"status"`
	Summary     string          `json:"summary"`
	Evidence    []Evidence      `json:"evidence"`
	Findings    []Finding       `json:"findings"`
	Timeline    []TimelineEntry `json:"timeline"`
	Gaps        []Gap           `json:"gaps"`
}

// Key percent-encodes whitespace in the locator part of an evidence id: ids are whitespace-free by contract, and a
// path may contain spaces. Same rule as the Windows agent's Builder.Key.
func Key(locator string) string {
	var b strings.Builder
	for _, r := range locator {
		if unicode.IsSpace(r) {
			fmt.Fprintf(&b, "%%%02X", r)
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// Str is a convenience for the optional string fields.
func Str(s string) *string { return &s }
