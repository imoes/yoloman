package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/collect"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

func newOverviewTestServer(t *testing.T, cfg RESTConfig) (*httptest.Server, store.Store) {
	t.Helper()
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	cfg.Store = st
	return httptest.NewServer(NewRESTHandler(cfg)), st
}

func getOverview(t *testing.T, srv *httptest.Server) HostsOverviewResponse {
	t.Helper()
	resp, err := http.Get(srv.URL + "/api/v1/hosts/overview")
	if err != nil {
		t.Fatalf("GET /api/v1/hosts/overview: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out HostsOverviewResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	return out
}

func TestHostsOverview_SelfOnly(t *testing.T) {
	checkReg := collect.NewCheckRegistry()
	checkReg.Set("CPU load", checks.Result{Status: checks.StatusOK, Message: "load fine"}, time.Now())

	srv, st := newOverviewTestServer(t, RESTConfig{
		Mode:          "standalone",
		HostName:      "duppy1",
		CheckRegistry: checkReg,
	})
	defer srv.Close()

	now := time.Now()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "cpu_load1", Timestamp: now, Value: 0.5},
		{Metric: "disk_used_pct", Timestamp: now, Value: 42.0, Labels: map[string]string{"mount": "/"}},
	}); err != nil {
		t.Fatalf("WritePoints: %v", err)
	}

	out := getOverview(t, srv)
	if len(out.Hosts) != 1 {
		t.Fatalf("expected exactly 1 host (self only, no proxy), got %d: %+v", len(out.Hosts), out.Hosts)
	}
	host := out.Hosts[0]
	if host.Host != "duppy1" {
		t.Errorf("host = %q, want duppy1", host.Host)
	}
	if host.Mode != "standalone" {
		t.Errorf("mode = %q, want standalone", host.Mode)
	}
	if host.Parent != "" {
		t.Errorf("parent = %q, want empty (not a satellite)", host.Parent)
	}
	if host.LastSampleAt == "" {
		t.Errorf("expected a non-empty last_sample_at")
	}

	foundLoad, foundDisk := false, false
	for _, m := range host.Metrics {
		if m.Metric == "cpu_load1" && m.Value == 0.5 {
			foundLoad = true
		}
		if m.Metric == "disk_used_pct" && m.Value == 42.0 && m.Labels["mount"] == "/" {
			foundDisk = true
		}
	}
	if !foundLoad {
		t.Errorf("expected cpu_load1=0.5 in metrics, got %+v", host.Metrics)
	}
	if !foundDisk {
		t.Errorf("expected disk_used_pct{mount=/}=42.0 in metrics, got %+v", host.Metrics)
	}

	if len(host.Checks) != 1 || host.Checks[0].Name != "CPU load" || host.Checks[0].Status != "OK" {
		t.Errorf("expected the registered CPU load check, got %+v", host.Checks)
	}
}

func TestHostsOverview_OnlyLatestPointPerSeriesReturned(t *testing.T) {
	srv, st := newOverviewTestServer(t, RESTConfig{Mode: "standalone", HostName: "h1"})
	defer srv.Close()

	older := time.Now().Add(-time.Hour)
	newer := time.Now()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "mem_used_pct", Timestamp: older, Value: 10},
		{Metric: "mem_used_pct", Timestamp: newer, Value: 99},
	}); err != nil {
		t.Fatalf("WritePoints: %v", err)
	}

	out := getOverview(t, srv)
	count := 0
	var value float64
	for _, m := range out.Hosts[0].Metrics {
		if m.Metric == "mem_used_pct" {
			count++
			value = m.Value
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 mem_used_pct sample (the latest), got %d", count)
	}
	if value != 99 {
		t.Errorf("mem_used_pct = %v, want 99 (the newer point)", value)
	}
}

func TestHostsOverview_ProxyIncludesSatellites(t *testing.T) {
	cache := fleet.NewSnapshotCache()
	cache.Set("duppy-leaf", fleet.HostSnapshot{
		Host:         "duppy-leaf",
		Mode:         "standalone",
		LastSampleAt: "2026-01-01T00:00:00Z",
		Metrics:      []fleet.MetricSample{{Metric: "cpu_load1", Value: 0.1}},
		Checks:       []fleet.CheckSnapshot{{Name: "Memory", Status: "OK", Message: "fine"}},
	})

	srv, _ := newOverviewTestServer(t, RESTConfig{
		Mode:               "proxy",
		HostName:           "selecta1",
		SatelliteSnapshots: cache,
	})
	defer srv.Close()

	out := getOverview(t, srv)
	if len(out.Hosts) != 2 {
		t.Fatalf("expected self + 1 satellite = 2 hosts, got %d: %+v", len(out.Hosts), out.Hosts)
	}

	var self, sat *HostSnapshot
	for i := range out.Hosts {
		switch out.Hosts[i].Host {
		case "selecta1":
			self = &out.Hosts[i]
		case "duppy-leaf":
			sat = &out.Hosts[i]
		}
	}
	if self == nil {
		t.Fatalf("expected a self host named selecta1, got %+v", out.Hosts)
	}
	if self.Mode != "proxy" {
		t.Errorf("self mode = %q, want proxy", self.Mode)
	}
	if sat == nil {
		t.Fatalf("expected a satellite host named duppy-leaf, got %+v", out.Hosts)
	}
	if sat.Parent != "selecta1" {
		t.Errorf("satellite parent = %q, want selecta1", sat.Parent)
	}
	if sat.Mode != "satellite" {
		t.Errorf("satellite mode = %q, want satellite", sat.Mode)
	}
	if len(sat.Metrics) != 1 || sat.Metrics[0].Metric != "cpu_load1" {
		t.Errorf("expected the cached satellite metric to pass through, got %+v", sat.Metrics)
	}
	if len(sat.Checks) != 1 || sat.Checks[0].Name != "Memory" {
		t.Errorf("expected the cached satellite check to pass through, got %+v", sat.Checks)
	}
}

func TestHostsOverview_StandaloneModeIgnoresEmptySatelliteCache(t *testing.T) {
	srv, _ := newOverviewTestServer(t, RESTConfig{Mode: "standalone", HostName: "h1", SatelliteSnapshots: fleet.NewSnapshotCache()})
	defer srv.Close()

	out := getOverview(t, srv)
	if len(out.Hosts) != 1 {
		t.Fatalf("standalone mode should never append satellites even if a cache is set, got %d hosts", len(out.Hosts))
	}
}
