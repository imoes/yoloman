package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestTemplate_RendersContentPlaceholders(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "app.conf")
	tpl := NewTemplate()
	res, err := tpl.Run(context.Background(), map[string]any{
		"dest":    dest,
		"content": "server_name {{ hostname }};\nlisten {{ port }};\n",
		"vars":    map[string]any{"hostname": "example.com", "port": "8080"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first render")
	}
	got, _ := os.ReadFile(dest)
	want := "server_name example.com;\nlisten 8080;\n"
	if string(got) != want {
		t.Errorf("content = %q, want %q", got, want)
	}
}

func TestTemplate_MissingVarErrors(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "app.conf")
	tpl := NewTemplate()
	_, err := tpl.Run(context.Background(), map[string]any{
		"dest": dest, "content": "value={{ missing }}",
	}, false)
	if err == nil {
		t.Fatal("expected error for a placeholder with no corresponding var")
	}
	if _, statErr := os.Stat(dest); statErr == nil {
		t.Error("expected dest to not be written when rendering fails")
	}
}

func TestTemplate_Idempotent(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "app.conf")
	tpl := NewTemplate()
	args := map[string]any{"dest": dest, "content": "x={{ v }}", "vars": map[string]any{"v": "1"}}
	if _, err := tpl.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := tpl.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when rendered content already matches dest")
	}
}

func TestTemplate_FromSrc(t *testing.T) {
	dir := t.TempDir()
	srcPath := filepath.Join(dir, "tpl.txt")
	if err := os.WriteFile(srcPath, []byte("hello {{ name }}"), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(dir, "out.txt")
	tpl := NewTemplate()
	_, err := tpl.Run(context.Background(), map[string]any{
		"dest": dest, "src": srcPath, "vars": map[string]any{"name": "world"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "hello world" {
		t.Errorf("content = %q, want %q", got, "hello world")
	}
}

func TestTemplate_BothContentAndSrcRejected(t *testing.T) {
	tpl := NewTemplate()
	_, err := tpl.Run(context.Background(), map[string]any{
		"dest": "/tmp/x", "content": "a", "src": "/tmp/b",
	}, false)
	if err == nil {
		t.Fatal("expected error when both content and src are given")
	}
}

func TestTemplate_NoPlaceholdersRendersLiterally(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "plain.txt")
	tpl := NewTemplate()
	res, err := tpl.Run(context.Background(), map[string]any{"dest": dest, "content": "no placeholders here"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "no placeholders here" {
		t.Errorf("content = %q", got)
	}
}

func TestTemplate_DryRunDoesNotWrite(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "app.conf")
	tpl := NewTemplate()
	res, err := tpl.Run(context.Background(), map[string]any{
		"dest": dest, "content": "x={{ v }}", "vars": map[string]any{"v": "1"}, "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("expected dest to NOT exist after dry_run")
	}
}
