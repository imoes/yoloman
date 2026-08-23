package starmodules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

const writerStar = `
def main(ctx, params):
    p = params["path"]
    changed = ctx.file_write(p, "hello\n", mode="0644")
    return {"changed": changed, "msg": "wrote " + p, "data": {"path": p}}
`

func writerSidecar(writes string) []byte {
	return []byte("name: writer\nfqcn: test.writer\ncollection: test\n" +
		"short_description: writes a file\noptions:\n  path: {type: path, required: true}\n" +
		"writes: " + writes + "\nruntime: starlark\n")
}

func build(t *testing.T, star string, sidecar []byte, agentWrite bool) *StarModule {
	t.Helper()
	m, err := BuildModule([]byte(star), sidecar, "yaml", agentWrite)
	if err != nil {
		t.Fatalf("BuildModule: %v", err)
	}
	return m
}

func TestStarModule_Metadata(t *testing.T) {
	m := build(t, writerStar, writerSidecar("true"), true)
	if m.Name() != "test.writer" || !m.Writes() {
		t.Fatalf("unexpected: name=%s writes=%v", m.Name(), m.Writes())
	}
	schema := m.InputSchema()
	req, _ := schema["required"].([]string)
	if len(req) != 1 || req[0] != "path" {
		t.Errorf("InputSchema required = %v, want [path]", schema["required"])
	}
}

func TestStarModule_CheckModePredictsWithoutWriting(t *testing.T) {
	m := build(t, writerStar, writerSidecar("true"), true)
	p := filepath.Join(t.TempDir(), "out.txt")

	res, err := m.Run(context.Background(), map[string]any{"path": p}, true) // dry-run
	if err != nil {
		t.Fatalf("Run(dry): %v", err)
	}
	if !res.Changed {
		t.Error("dry-run should predict changed=true for a missing file")
	}
	if _, statErr := os.Stat(p); !os.IsNotExist(statErr) {
		t.Error("check_mode must NOT create the file")
	}
}

func TestStarModule_RealWriteThenIdempotent(t *testing.T) {
	m := build(t, writerStar, writerSidecar("true"), true)
	p := filepath.Join(t.TempDir(), "out.txt")

	res, err := m.Run(context.Background(), map[string]any{"path": p}, false)
	if err != nil || !res.Changed {
		t.Fatalf("first write: res=%+v err=%v", res, err)
	}
	b, _ := os.ReadFile(p)
	if string(b) != "hello\n" {
		t.Fatalf("content = %q", b)
	}
	// data round-trip (starlarkToGo)
	data, _ := res.Data.(map[string]any)
	if data["path"] != p {
		t.Errorf("data.path = %v, want %s", data["path"], p)
	}

	res2, err := m.Run(context.Background(), map[string]any{"path": p}, false)
	if err != nil || res2.Changed {
		t.Errorf("second write should be idempotent: res=%+v err=%v", res2, err)
	}
}

func TestStarModule_MissingRequiredParam(t *testing.T) {
	m := build(t, writerStar, writerSidecar("true"), true)
	if _, err := m.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing required param 'path'")
	}
}

func TestStarModule_WriteGateClosed(t *testing.T) {
	m := build(t, writerStar, writerSidecar("true"), false) // agentWrite=false
	p := filepath.Join(t.TempDir(), "out.txt")
	_, err := m.Run(context.Background(), map[string]any{"path": p}, false)
	if err == nil {
		t.Fatal("expected write-gate error when agentWrite=false")
	}
	if _, statErr := os.Stat(p); !os.IsNotExist(statErr) {
		t.Error("nothing should be written when the gate is closed")
	}
}

func TestStarModule_ReadOnlyModuleCannotMutate(t *testing.T) {
	// A module declared writes:false must not be able to file_write.
	m := build(t, writerStar, writerSidecar("false"), true)
	p := filepath.Join(t.TempDir(), "out.txt")
	if _, err := m.Run(context.Background(), map[string]any{"path": p}, false); err == nil {
		t.Fatal("expected error: a read-only module may not mutate")
	}
}

const runStar = `
def main(ctx, params):
    res = ctx.run(["/bin/sh", "-c", "echo out; exit 3"], ok_codes=[0, 3])
    return {"changed": False, "msg": "ran", "data": {"rc": res.rc, "stdout": res.stdout, "skipped": res.skipped}}
`

func TestStarModule_RunReturnsRcAsData(t *testing.T) {
	sidecar := []byte("name: prober\nfqcn: test.prober\ncollection: test\nshort_description: probes\noptions: {}\nwrites: false\nruntime: starlark\n")
	m := build(t, runStar, sidecar, true)
	res, err := m.Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"].(int64) != 3 {
		t.Errorf("rc = %v, want 3 (non-zero exit is data, not an error)", data["rc"])
	}
	if data["stdout"].(string) != "out\n" {
		t.Errorf("stdout = %q", data["stdout"])
	}
}

const mutateRunStar = `
def main(ctx, params):
    res = ctx.run(["/bin/touch", params["path"]], mutates=True)
    return {"changed": not res.skipped, "msg": "touched", "data": {"skipped": res.skipped}}
`

func TestStarModule_MutatingRunSkippedInCheckMode(t *testing.T) {
	sidecar := []byte("name: toucher\nfqcn: test.toucher\ncollection: test\nshort_description: t\noptions:\n  path: {type: path, required: true}\nwrites: true\nruntime: starlark\n")
	m := build(t, mutateRunStar, sidecar, true)
	p := filepath.Join(t.TempDir(), "touched")
	res, err := m.Run(context.Background(), map[string]any{"path": p}, true) // dry-run
	if err != nil {
		t.Fatalf("Run(dry): %v", err)
	}
	if res.Changed {
		t.Error("mutating run must be skipped (changed=false) in check_mode")
	}
	if _, statErr := os.Stat(p); !os.IsNotExist(statErr) {
		t.Error("check_mode must not touch the file")
	}
}

func TestLoadDir_LoadsPairsAndSkipsInvalid(t *testing.T) {
	dir := t.TempDir()
	col := filepath.Join(dir, "test")
	if err := os.MkdirAll(col, 0o755); err != nil {
		t.Fatal(err)
	}
	// valid, yaml sidecar
	os.WriteFile(filepath.Join(col, "writer.star"), []byte(writerStar), 0o644)
	os.WriteFile(filepath.Join(col, "writer.yaml"), writerSidecar("true"), 0o644)
	// valid, nt sidecar
	os.WriteFile(filepath.Join(col, "prober.star"), []byte(runStar), 0o644)
	// A YAML sidecar. This fixture was .nt — the format is gone, and the loader used to PREFER it, so the
	// test was the last thing keeping that preference alive.
	os.WriteFile(filepath.Join(col, "prober.yaml"), []byte("name: prober\nfqcn: test.prober\ncollection: test\nshort_description: p\noptions: {}\nwrites: false\nruntime: starlark\n"), 0o644)
	// invalid .star (no main) → skipped with a warning
	os.WriteFile(filepath.Join(col, "broken.star"), []byte("x = 1\n"), 0o644)
	os.WriteFile(filepath.Join(col, "broken.yaml"), []byte("name: broken\nfqcn: test.broken\ncollection: test\nshort_description: b\noptions: {}\nwrites: false\nruntime: starlark\n"), 0o644)

	mods, warnings, err := LoadDir(dir, true)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	names := map[string]bool{}
	for _, m := range mods {
		names[m.Name()] = true
	}
	if !names["test.writer"] || !names["test.prober"] {
		t.Errorf("expected writer+prober loaded, got %v", names)
	}
	if names["test.broken"] {
		t.Error("invalid module must be skipped")
	}
	if len(warnings) != 1 {
		t.Errorf("expected 1 warning for broken.star, got %v", warnings)
	}
}

func TestLoadDir_MissingDirIsNoError(t *testing.T) {
	mods, warnings, err := LoadDir(filepath.Join(t.TempDir(), "nope"), true)
	if err != nil || len(mods) != 0 || len(warnings) != 0 {
		t.Errorf("missing dir should be a clean no-op, got mods=%d warnings=%v err=%v", len(mods), warnings, err)
	}
}
