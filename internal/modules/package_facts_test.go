package modules

import (
	"context"
	"errors"
	"testing"
)

func TestPackageFacts_ParsesDpkgQueryOutput(t *testing.T) {
	canned := "install ok installed\tbash\t5.2.21-2ubuntu4\tamd64\n" +
		"install ok installed\tcurl\t8.5.0-2ubuntu10\tamd64\n"

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

// A package removed with `apt-get remove` keeps its conffiles and stays in
// dpkg's database as "rc" (deinstall ok config-files). It is not installed.
func TestPackageFacts_SkipsRemovedPackages(t *testing.T) {
	canned := "install ok installed\tbash\t5.2\tamd64\n" +
		"deinstall ok config-files\tmemcached\t1.6.18-1\tamd64\n" +
		"unknown ok not-installed\tfoo\t\tamd64\n" +
		"install ok half-configured\tbar\t1.0\tamd64\n"
	m := &PackageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte(canned), nil
	}}
	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	pkgs := res.Data.([]map[string]any)
	if len(pkgs) != 1 || pkgs[0]["name"] != "bash" {
		t.Fatalf("only bash is installed, got %+v", pkgs)
	}
}

func TestPackageFacts_RpmFallbackKeepsAll(t *testing.T) {
	m := &PackageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "dpkg-query" {
			return nil, errors.New("not found")
		}
		return []byte("redis\t7.2.5-1.el9\tx86_64\nbash\t5.1-1\tx86_64\n"), nil
	}}
	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if pkgs := res.Data.([]map[string]any); len(pkgs) != 2 || pkgs[0]["name"] != "redis" {
		t.Fatalf("rpm lines kept as-is, got %+v", pkgs)
	}
}
