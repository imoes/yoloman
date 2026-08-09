package pipeline

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTempPolicy(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "commands.yaml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadPolicy_ParsesAllowList(t *testing.T) {
	path := writeTempPolicy(t, `
allow:
  - binary: grep
  - binary: find
    forbid_patterns:
      - "-exec"
      - "-delete"
`)
	p, err := LoadPolicy(path)
	if err != nil {
		t.Fatalf("LoadPolicy: %v", err)
	}
	if len(p.Allow) != 2 {
		t.Fatalf("expected 2 allowed commands, got %d", len(p.Allow))
	}
}

func TestLoadPolicy_InvalidForbidPatternRejected(t *testing.T) {
	path := writeTempPolicy(t, `
allow:
  - binary: find
    forbid_patterns:
      - "[invalid"
`)
	if _, err := LoadPolicy(path); err == nil {
		t.Fatal("expected error for invalid regex in forbid_patterns")
	}
}

func TestLoadPolicy_MissingFile(t *testing.T) {
	if _, err := LoadPolicy(filepath.Join(t.TempDir(), "nope.yaml")); err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestPolicy_ValidateAllowsListedBinary(t *testing.T) {
	p := &Policy{Allow: []AllowedCommand{{Binary: "grep"}}}
	if err := p.Validate([]string{"grep", "-i", "error"}); err != nil {
		t.Errorf("expected grep to be allowed, got %v", err)
	}
}

func TestPolicy_ValidateRejectsUnlistedBinary(t *testing.T) {
	p := &Policy{Allow: []AllowedCommand{{Binary: "grep"}}}
	if err := p.Validate([]string{"rm", "-rf", "/"}); err == nil {
		t.Fatal("expected rm to be rejected as not in allow list")
	}
}

func TestPolicy_ValidateRejectsForbiddenArgs(t *testing.T) {
	p := &Policy{Allow: []AllowedCommand{{
		Binary:         "find",
		ForbidPatterns: []string{`-exec\b`, `-delete\b`},
	}}}
	if err := p.Validate([]string{"find", "/tmp", "-name", "*.log", "-exec", "rm", "{}", ";"}); err == nil {
		t.Fatal("expected -exec to be rejected")
	}
	if err := p.Validate([]string{"find", "/tmp", "-delete"}); err == nil {
		t.Fatal("expected -delete to be rejected")
	}
	if err := p.Validate([]string{"find", "/tmp", "-name", "*.log"}); err != nil {
		t.Errorf("expected a plain find to be allowed, got %v", err)
	}
}

func TestPolicy_ValidateEmptyStage(t *testing.T) {
	p := EmptyPolicy()
	if err := p.Validate(nil); err == nil {
		t.Fatal("expected error for empty stage")
	}
}

func TestEmptyPolicy_AllowsNothing(t *testing.T) {
	p := EmptyPolicy()
	if err := p.Validate([]string{"echo", "hi"}); err == nil {
		t.Fatal("expected EmptyPolicy to reject everything")
	}
}
