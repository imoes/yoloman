package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// A config.yaml shaped like an installed host: services on, no drop_metrics, and — critically for the
// scope test — a token and a listen address the endpoint must never be able to touch.
const seedConfig = `listen: "0.0.0.0:8010"
token: "super-secret-do-not-touch"
write: false
allow_self_config: true
collect:
  enabled: true
  interval: 60s
  services: true
  docker: true
  psi: false
db:
  driver: sqlite
  path: /var/lib/agentic-mcp/agentic-mcp.db
`

func seedConfigFile(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte(seedConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// captureRestart swaps the restart hook for one that only records it fired, and restores it after.
func captureRestart(t *testing.T) *bool {
	t.Helper()
	fired := false
	prev := scheduleSelfConfigRestart
	scheduleSelfConfigRestart = func() error { fired = true; return nil }
	t.Cleanup(func() { scheduleSelfConfigRestart = prev })
	return &fired
}

func postCollect(t *testing.T, srv *httptest.Server, body map[string]any) *http.Response {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(srv.URL+"/api/v1/agent/collect-config", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	return resp
}

func TestCollectConfig_WritesTheKnobsAndSchedulesRestart(t *testing.T) {
	fired := captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	resp := postCollect(t, srv, map[string]any{"services": false})
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	resp.Body.Close()

	got, err := config.Load(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got.Collect.Services {
		t.Error("services was not turned off")
	}
	if !*fired {
		t.Error("a change must schedule a restart, or the running agent keeps the old settings")
	}
}

// The property the design rests on: it can change the collect block AND the master write gate (a
// provisioned host enrols read-only and must be able to enable writes over the API), but it can NEVER
// reach auth or the listen address — those fields simply do not exist on the request.
func TestCollectConfig_CannotTouchAuthOrListen(t *testing.T) {
	captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	// Throw the dangerous keys at it anyway; token/listen must be ignored. write IS a legitimate field.
	resp := postCollect(t, srv, map[string]any{
		"services": false,
		"token":    "attacker",
		"listen":   "0.0.0.0:9999",
		"write":    true,
	})
	resp.Body.Close()

	got, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Token != "super-secret-do-not-touch" {
		t.Errorf("token changed to %q — the endpoint must never touch auth", got.Token)
	}
	if got.Listen != "0.0.0.0:8010" {
		t.Errorf("listen changed to %q", got.Listen)
	}
	if !got.Write {
		t.Error("write gate was not enabled — the owner-scoped carve-out must be able to set it")
	}
	if got.Collect.Services {
		t.Error("the one legitimate change (services:false) did not apply")
	}
}

func TestCollectConfig_AbsentFieldsAreLeftAlone(t *testing.T) {
	captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	// Only services. docker was true in the seed and must stay true.
	postCollect(t, srv, map[string]any{"services": false}).Body.Close()

	got, _ := config.Load(path)
	if !got.Collect.Docker {
		t.Error("docker was turned off, but the request never mentioned it")
	}
	if got.Collect.Services {
		t.Error("services should be off")
	}
}

func TestCollectConfig_NoOpDoesNotRestart(t *testing.T) {
	fired := captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	resp := postCollect(t, srv, map[string]any{}) // nothing set
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	if out["status"] != "unchanged" {
		t.Errorf("status = %v, want unchanged", out["status"])
	}
	if *fired {
		t.Error("an empty patch bounced the agent for nothing")
	}
}

func TestCollectConfig_GateOffIsForbidden(t *testing.T) {
	captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: false, ConfigPath: path}))
	defer srv.Close()

	resp := postCollect(t, srv, map[string]any{"services": false})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
	resp.Body.Close()
	got, _ := config.Load(path)
	if !got.Collect.Services {
		t.Error("config changed despite the gate being off")
	}
}

func TestCollectConfig_BadIntervalIsRejectedAndNothingWritten(t *testing.T) {
	fired := captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	resp := postCollect(t, srv, map[string]any{"interval": "not-a-duration"})
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", resp.StatusCode)
	}
	resp.Body.Close()
	if *fired {
		t.Error("a rejected request must not restart the agent")
	}
}

func TestCollectConfig_SetsMonitoredContainersWholesale(t *testing.T) {
	// The container allow-list is replaced, not merged: Bossman sends the full accepted set. An empty
	// list is a real instruction ("nothing monitored"), so it must be distinguishable from absent.
	captureRestart(t)
	path := seedConfigFile(t)
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfConfig: true, ConfigPath: path}))
	defer srv.Close()

	postCollect(t, srv, map[string]any{"monitored_containers": []string{"web", "db"}}).Body.Close()
	got, _ := config.Load(path)
	if len(got.Collect.MonitoredContainers) != 2 {
		t.Fatalf("monitored_containers = %v, want [web db]", got.Collect.MonitoredContainers)
	}

	// Sending an empty list must CLEAR it — "un-monitor everything", not a no-op.
	postCollect(t, srv, map[string]any{"monitored_containers": []string{}}).Body.Close()
	got, _ = config.Load(path)
	if len(got.Collect.MonitoredContainers) != 0 {
		t.Errorf("empty list must clear the allow-list, got %v", got.Collect.MonitoredContainers)
	}
}
