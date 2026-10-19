package diagnosis

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
)

const repoConfigs = "../../configs"

func goldens(t *testing.T) map[string][]byte {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(repoConfigs, "schemas", "diagnosis.examples", "*.json"))
	if err != nil || len(files) < 4 {
		t.Fatalf("golden documents: %v (%d found)", err, len(files))
	}
	out := map[string][]byte{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		out[filepath.Base(f)] = b
	}
	return out
}

func generic(t *testing.T, b []byte) any {
	t.Helper()
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func resolvedSchema(t *testing.T) *jsonschema.Resolved {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoConfigs, "schemas", "diagnosis.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var s jsonschema.Schema
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	rs, err := s.Resolve(nil)
	if err != nil {
		t.Fatalf("resolve schema: %v", err)
	}
	return rs
}

// The Go model carries every field of the contract: a golden document decoded and encoded again is the same
// document (structurally — key order and whitespace aside). A field the model forgot would vanish here.
func TestGoldenDocumentsRoundTripThroughTheModel(t *testing.T) {
	for name, b := range goldens(t) {
		var d Diagnosis
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&d); err != nil {
			t.Fatalf("%s: decode into the model: %v", name, err)
		}
		again, err := json.Marshal(&d)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(generic(t, b), generic(t, again)) {
			t.Errorf("%s: the model does not reproduce the document:\n%s", name, again)
		}
	}
}

func TestGoldenDocumentsHoldTheContract(t *testing.T) {
	cat, err := LoadCatalogue()
	if err != nil {
		t.Fatal(err)
	}
	rs := resolvedSchema(t)
	for name, b := range goldens(t) {
		var d Diagnosis
		if err := json.Unmarshal(b, &d); err != nil {
			t.Fatal(err)
		}
		if v := Validate(&d, cat); len(v) > 0 {
			t.Errorf("%s: %v", name, v)
		}
		if err := rs.Validate(generic(t, b)); err != nil {
			t.Errorf("%s: schema: %v", name, err)
		}
	}
}

func TestEmbeddedCatalogueIsTheRepoCatalogue(t *testing.T) {
	repo, err := os.ReadFile(filepath.Join(repoConfigs, "diagnosis_rules.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(repo, rulesJSON) {
		t.Fatal("internal/diagnosis/rules.json differs from configs/diagnosis_rules.json — copy it (cp configs/diagnosis_rules.json internal/diagnosis/rules.json)")
	}
}

func newProbe(t *testing.T) *Builder {
	t.Helper()
	b, err := NewBuilder("test-1", "e2e-deb-1", "linux", Target{Kind: "service", Name: "probe.service"},
		time.Date(2026, 10, 17, 14, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func at(s string) *time.Time { t, _ := time.Parse(time.RFC3339, s); return &t }

func TestBuilderProducesADocumentThatHoldsAndMatchesTheSchema(t *testing.T) {
	b := newProbe(t)
	show := b.Evidence(Evidence{ID: "systemd:show:probe.service", Source: "systemctl show", Observed: at("2026-10-17T13:59:58Z"),
		Fact: "probe.service is failed with Result=exit-code, ExecMainStatus=203 (EXEC).", Raw: map[string]string{"Result": "exit-code"}})
	stat := b.Evidence(Evidence{ID: "file:stat:/usr/bin/nope", Source: "stat", Fact: "/usr/bin/nope does not exist.", Raw: map[string]any{"exists": false}})
	if err := b.Find(Finding{RuleID: "svc.image_missing", Certainty: Proven, EvidenceIDs: []string{show, stat},
		Claim: "probe.service does not start because the program it runs, /usr/bin/nope, does not exist."}); err != nil {
		t.Fatal(err)
	}
	d, err := b.Build(StatusFailed)
	if err != nil {
		t.Fatal(err)
	}
	if d.Summary != d.Findings[0].Claim || len(d.Timeline) != 1 {
		t.Fatalf("summary/timeline: %+v", d)
	}
	out, _ := json.Marshal(d)
	if err := resolvedSchema(t).Validate(generic(t, out)); err != nil {
		t.Fatalf("schema: %v\n%s", err, out)
	}
}

func TestBuilderRefusesWhatTheContractForbids(t *testing.T) {
	cases := map[string]struct {
		f    Finding
		want string
	}{
		"no evidence":    {Finding{RuleID: "svc.image_missing", Certainty: Proven, Claim: "x"}, "without evidence"},
		"dangling":       {Finding{RuleID: "svc.image_missing", Certainty: Proven, Claim: "x", EvidenceIDs: []string{"systemd:show:other"}}, "not recorded"},
		"unknown gap":    {Finding{RuleID: "svc.unexplained", Certainty: Unknown, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"}}, "Unknown must name"},
		"over-certain":   {Finding{RuleID: "svc.config_invalid", Certainty: Proven, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"}}, "exceeds the rule's maximum Likely"},
		"other platform": {Finding{RuleID: "svc.logon_right_missing", Certainty: Proven, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"}}, "does not apply to platform linux"},
		"unknown rule":   {Finding{RuleID: "svc.guessed", Certainty: Likely, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"}}, "not in the catalogue"},
		"precedent only": {Finding{RuleID: "svc.image_missing", Certainty: Proven, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"},
			Precedent: &Precedent{EvidenceID: "systemd:show:probe.service", Change: "c", Observed: time.Now()}}, "correlation, not a cause"},
		"wrong remedy": {Finding{RuleID: "svc.timeout", Certainty: Proven, Claim: "x", EvidenceIDs: []string{"systemd:show:probe.service"},
			Remedy: &Remedy{Action: "set", Target: RemedyTarget{Kind: "user_right", ID: "x"}}}, "not one the rule offers"},
	}
	for name, c := range cases {
		b := newProbe(t)
		b.Evidence(Evidence{ID: "systemd:show:probe.service", Source: "systemctl show", Fact: "f", Raw: nil})
		err := b.Find(c.f)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v, want %q", name, err, c.want)
		}
		if _, err := b.Build(StatusFailed); !errors.Is(err, ErrRefused) {
			t.Errorf("%s: Build must fail after a refusal, got %v", name, err)
		}
	}
}

func TestAStoppedTargetWithoutFindingDoesNotBuild(t *testing.T) {
	b := newProbe(t)
	b.Evidence(Evidence{ID: "systemd:show:probe.service", Source: "systemctl show", Fact: "f", Raw: nil})
	if _, err := b.Build(StatusFailed); err == nil || !strings.Contains(err.Error(), "svc.unexplained") {
		t.Fatalf("got %v", err)
	}
	b2 := newProbe(t)
	id := b2.Evidence(Evidence{ID: "systemd:show:probe.service", Source: "systemctl show", Fact: "f", Raw: nil})
	if err := b2.Unexplained([]string{id}, "the journal holds nothing for this invocation"); err != nil {
		t.Fatal(err)
	}
	if d, err := b2.Build(StatusFailed); err != nil || d.Findings[0].Certainty != Unknown {
		t.Fatalf("got %v / %+v", err, d)
	}
}

func TestFindingsAreOrderedByTheCatalogue(t *testing.T) {
	b := newProbe(t)
	id := b.Evidence(Evidence{ID: "systemd:show:probe.service", Source: "systemctl show", Fact: "f", Raw: nil})
	_ = b.Find(Finding{RuleID: "svc.exits_immediately", Certainty: Proven, Claim: "exits", EvidenceIDs: []string{id}})
	_ = b.Find(Finding{RuleID: "svc.dependency_failed", Certainty: Proven, Claim: "dependency", EvidenceIDs: []string{id}})
	d, err := b.Build(StatusFailed)
	if err != nil {
		t.Fatal(err)
	}
	if d.Findings[0].RuleID != "svc.dependency_failed" || d.Summary != "dependency" {
		t.Fatalf("order: %v", d.Findings)
	}
}

// The schema validator really validates (a green golden run would also come from a validator that accepts
// everything): an Unknown without its gap and a finding without evidence are refused by the SCHEMA itself.
func TestTheSchemaRefusesWhatItShould(t *testing.T) {
	rs := resolvedSchema(t)
	b := goldens(t)["unknown-gap.json"]
	doc := generic(t, b).(map[string]any)
	doc["findings"].([]any)[0].(map[string]any)["gap"] = nil
	if err := rs.Validate(doc); err == nil {
		t.Error("an Unknown finding without a gap passed the schema")
	}
	doc = generic(t, b).(map[string]any)
	doc["findings"].([]any)[0].(map[string]any)["evidence_ids"] = []any{}
	if err := rs.Validate(doc); err == nil {
		t.Error("a finding without evidence passed the schema")
	}
}
