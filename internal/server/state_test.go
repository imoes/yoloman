package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/desiredstate"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

func TestState_DisabledWhenNoConsumer(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Store: st}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/v1/state")
	if err != nil {
		t.Fatalf("GET /api/v1/state: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["desired_state"] != "unconfigured" {
		t.Fatalf("body = %+v, want unconfigured", out)
	}
}

func TestState_ReportsConsumerStatus(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	// An applier that has never been pushed reports has_state=false.
	da := desiredstate.NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Store: st, DesiredState: da}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/v1/state")
	if err != nil {
		t.Fatalf("GET /api/v1/state: %v", err)
	}
	defer resp.Body.Close()
	var out desiredstate.Status
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.HasState {
		t.Fatalf("has_state = true, want false for a never-pushed applier")
	}
}

func TestConfigApply_PushStoresAndStateReflects(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	da := desiredstate.NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	// Write:true — applying pushed config is a write action.
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Store: st, DesiredState: da, Write: true}))
	defer srv.Close()

	body := `{"generation": 4, "config_hash": "abc", "state": {"monitoring": {"checks": ["ping"]}}}`
	resp, err := http.Post(srv.URL+"/api/v1/config/apply", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST /api/v1/config/apply: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var applyOut map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&applyOut)
	if applyOut["status"] != "applied" {
		t.Fatalf("apply response = %+v, want applied", applyOut)
	}
	if da.Status().Generation != 4 {
		t.Fatalf("applier gen = %d, want 4", da.Status().Generation)
	}
}

func TestConfigApply_ForbiddenWhenReadOnly(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	da := desiredstate.NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	// Write:false (default) — a read-only agent must refuse pushed config.
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Store: st, DesiredState: da, Write: false}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/api/v1/config/apply", "application/json",
		strings.NewReader(`{"generation":1,"config_hash":"x","state":{}}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
}
