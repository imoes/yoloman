package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
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
	if out["desired_state_consumer"] != "disabled" {
		t.Fatalf("body = %+v, want disabled", out)
	}
}

func TestState_ReportsConsumerStatus(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	// A consumer that has never pulled reports has_state=false.
	dc := desiredstate.NewConsumer("http://unused", "tok", filepath.Join(t.TempDir(), "ds.json"), nil)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Store: st, DesiredState: dc}))
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
		t.Fatalf("has_state = true, want false for a never-pulled consumer")
	}
}
