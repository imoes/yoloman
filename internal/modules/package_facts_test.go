package modules

import (
	"context"
	"errors"
	"testing"
)

func TestPackageFacts_ParsesDpkgQueryOutput(t *testing.T) {
	canned := "bash\t5.2.21-2ubuntu4\tamd64\n" +
		"curl\t8.5.0-2ubuntu10\tamd64\n"

	m := &PackageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name != "dpkg-query" {
			t.Errorf("expected dpkg-query, got %q", name)
		}
		return []byte(canned), nil
	}}

	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	pkgs := res.Data.([]map[string]any)
	if len(pkgs) != 2 {
		t.Fatalf("expected 2 packages, got %d: %+v", len(pkgs), pkgs)
	}
	if pkgs[0]["name"] != "bash" || pkgs[0]["version"] != "5.2.21-2ubuntu4" || pkgs[0]["arch"] != "amd64" {
		t.Errorf("unexpected first package: %+v", pkgs[0])
	}
}

func TestPackageFacts_RunnerError(t *testing.T) {
	m := &PackageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("dpkg-query: command not found")
	}}
	if _, err := m.Run(context.Background(), nil, false); err == nil {
		t.Fatal("expected error to propagate from runner")
	}
}

func TestPackageFacts_IsReadOnly(t *testing.T) {
	m := NewPackageFacts()
	if m.Writes() {
		t.Error("package_facts must be read-only")
	}
}
