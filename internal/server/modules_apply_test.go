package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

const applyStar = `
def main(ctx, params):
    return {"changed": False, "msg": "ok"}
`

const applySidecar = "name: ping2\nfqcn: test.ping2\ncollection: test\nshort_description: p\noptions: {}\nwrites: false\nruntime: starlark\n"

func applyBody(t *testing.T, withSha bool) []byte {
	t.Helper()
	sha := ""
	if withSha {
		sum := sha256.Sum256([]byte(applyStar))
		sha = hex.EncodeToString(sum[:])
	}
	b, _ := json.Marshal(map[string]any{"modules": []map[string]any{{
		"fqcn": "test.ping2", "star": applyStar, "sidecar": applySidecar, "sidecar_format": "yaml", "sha256": sha,
	}}})
	return b
}

func TestModulesApply_RegistersAndPersists(t *testing.T) {
	dir := t.TempDir()
	reg := NewDefaultModuleRegistry()
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: true, ModReg: reg, ModulesDir: dir}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/api/v1/modules/apply", "application/json", bytes.NewReader(applyBody(t, true)))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out struct {
		Applied int `json:"applied"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Applied != 1 {
		t.Fatalf("applied = %d, want 1", out.Applied)
	}
	// live-registered
	if _, ok := reg.Get("test.ping2"); !ok {
		t.Error("module not registered in the live registry")
	}
	// persisted so a restart reloads it
	if _, err := os.Stat(filepath.Join(dir, "test", "ping2.star")); err != nil {
		t.Errorf("module .star not persisted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "test", "ping2.yaml")); err != nil {
		t.Errorf("sidecar not persisted: %v", err)
	}
}

func TestModulesApply_ScriptModule(t *testing.T) {
	dir := t.TempDir()
	reg := NewDefaultModuleRegistry()
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: true, ModReg: reg, ModulesDir: dir}))
	defer srv.Close()

	script := "#!/usr/bin/env bash\ncat >/dev/null\necho '{\"changed\": false, \"msg\": \"ok\"}'\n"
	sidecar := "name: pinger\nfqcn: test.pinger\ncollection: test\nshort_description: p\noptions: {}\nwrites: false\n"
	sum := sha256.Sum256([]byte(script))
	body, _ := json.Marshal(map[string]any{"modules": []map[string]any{{
		"fqcn": "test.pinger", "star": script, "ext": ".sh", "sidecar": sidecar,
		"sidecar_format": "yaml", "sha256": hex.EncodeToString(sum[:]),
	}}})
	resp, err := http.Post(srv.URL+"/api/v1/modules/apply", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		Applied int `json:"applied"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Applied != 1 {
		t.Fatalf("applied = %d, want 1 (script module)", out.Applied)
	}
	if _, ok := reg.Get("test.pinger"); !ok {
		t.Error("script module not registered in the live registry")
	}
	// persisted under its language extension so a restart's LoadScriptDir reloads it
	if _, err := os.Stat(filepath.Join(dir, "test", "pinger.sh")); err != nil {
		t.Errorf("script not persisted as .sh: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "test", "pinger.yaml")); err != nil {
		t.Errorf("sidecar not persisted: %v", err)
	}
}

func TestModulesApply_ShaMismatchRejected(t *testing.T) {
	dir := t.TempDir()
	reg := NewDefaultModuleRegistry()
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: true, ModReg: reg, ModulesDir: dir}))
	defer srv.Close()

	body, _ := json.Marshal(map[string]any{"modules": []map[string]any{{
		"fqcn": "test.ping2", "star": applyStar, "sidecar": applySidecar, "sidecar_format": "yaml", "sha256": "deadbeef",
	}}})
	resp, err := http.Post(srv.URL+"/api/v1/modules/apply", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		Applied int              `json:"applied"`
		Results []map[string]any `json:"results"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Applied != 0 {
		t.Fatalf("applied = %d, want 0 (sha mismatch)", out.Applied)
	}
	if _, ok := reg.Get("test.ping2"); ok {
		t.Error("module must not register on sha mismatch")
	}
}

func TestModulesApply_ForbiddenWhenWriteFalse(t *testing.T) {
	reg := NewDefaultModuleRegistry()
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: false, ModReg: reg, ModulesDir: t.TempDir()}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/api/v1/modules/apply", "application/json", bytes.NewReader(applyBody(t, true)))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403 when write=false", resp.StatusCode)
	}
}

func TestModulesApply_InvalidStarRejected(t *testing.T) {
	dir := t.TempDir()
	reg := NewDefaultModuleRegistry()
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: true, ModReg: reg, ModulesDir: dir}))
	defer srv.Close()

	badStar := "x = 1\n" // no main → fails lint
	sum := sha256.Sum256([]byte(badStar))
	body, _ := json.Marshal(map[string]any{"modules": []map[string]any{{
		"fqcn": "test.bad", "star": badStar, "sidecar": "name: bad\nfqcn: test.bad\ncollection: test\nshort_description: b\noptions: {}\nwrites: false\nruntime: starlark\n",
		"sidecar_format": "yaml", "sha256": hex.EncodeToString(sum[:]),
	}}})
	resp, err := http.Post(srv.URL+"/api/v1/modules/apply", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		Applied int `json:"applied"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Applied != 0 {
		t.Fatalf("applied = %d, want 0 (invalid .star)", out.Applied)
	}
	var _ modules.Module // keep import
}
