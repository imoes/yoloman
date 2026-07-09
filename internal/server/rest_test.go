package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/store"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

func newRESTTestServer(t *testing.T, write bool) (*httptest.Server, store.Store) {
	t.Helper()
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	modReg := modules.NewRegistry()
	_ = modReg.Register(modules.NewStat())
	_ = modReg.Register(modules.NewCopy())
	_ = modReg.Register(modules.NewSystemd())

	deployTask, err := tasks.ParseFile([]byte(`
name: deploy_motd
description: "x"
copy:
  dest: ` + filepath.Join(t.TempDir(), "motd") + `
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`))
	if err != nil {
		t.Fatal(err)
	}

	policy := &pipeline.Policy{Allow: []pipeline.AllowedCommand{{Binary: "printf"}, {Binary: "grep"}}}

	handler := NewRESTHandler(RESTConfig{
		ProcRoot: "/proc",
		ModReg:   modReg,
		Tasks:    []*tasks.Task{deployTask},
		Policy:   policy,
		Store:    st,
		Write:    write,
	})
	return httptest.NewServer(handler), st
}

func doJSON(t *testing.T, method, url string, body any) *http.Response {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func decodeJSON(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decoding response JSON: %v", err)
	}
	return out
}

func TestREST_ListProcResources(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/proc", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	resources := out["resources"].([]any)
	found := false
	for _, r := range resources {
		if r == "meminfo" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected 'meminfo' in resource list, got %v", resources)
	}
}

func TestREST_GetProcResource(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/proc/meminfo", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var info map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	if _, ok := info["MemTotal"]; !ok {
		t.Errorf("expected MemTotal key in meminfo response, got %v", info)
	}
}

func TestREST_GetUnknownProcResource(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/proc/nonexistent", nil)
	if resp.StatusCode != 404 {
		t.Errorf("status = %d, want 404", resp.StatusCode)
	}
}

func TestREST_ListTools_WriteFalseHidesWriteTools(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/tools", nil)
	out := decodeJSON(t, resp)
	tools := out["tools"].([]any)

	names := map[string]bool{}
	for _, tRaw := range tools {
		tool := tRaw.(map[string]any)
		names[tool["name"].(string)] = true
	}
	if !names["stat"] {
		t.Error("expected read-only 'stat' tool listed")
	}
	if names["copy"] || names["deploy_motd"] || names["run_pipeline"] {
		t.Errorf("expected write tools hidden when write=false, got %v", names)
	}
}

func TestREST_ListTools_WriteTrueExposesWriteTools(t *testing.T) {
	srv, _ := newRESTTestServer(t, true)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/tools", nil)
	out := decodeJSON(t, resp)
	tools := out["tools"].([]any)

	names := map[string]bool{}
	for _, tRaw := range tools {
		tool := tRaw.(map[string]any)
		names[tool["name"].(string)] = true
	}
	for _, want := range []string{"stat", "copy", "deploy_motd", "run_pipeline"} {
		if !names[want] {
			t.Errorf("expected %q listed when write=true, got %v", want, names)
		}
	}
}

func TestREST_CallModuleTool(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/stat", map[string]any{"path": "/"})
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	data := out["data"].(map[string]any)
	if data["exists"] != true || data["isdir"] != true {
		t.Errorf("unexpected stat result: %+v", data)
	}
}

func TestREST_CallWriteToolRejectedWhenWriteFalse(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/copy", map[string]any{"dest": "/tmp/x", "content": "y"})
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403", resp.StatusCode)
	}
}

func TestREST_CallTaskTool(t *testing.T) {
	srv, _ := newRESTTestServer(t, true)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/deploy_motd", map[string]any{"message": "hello via REST"})
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	if out["changed"] != true {
		t.Errorf("expected changed=true, got %+v", out)
	}
}

func TestREST_CallUnknownTool(t *testing.T) {
	srv, _ := newRESTTestServer(t, true)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/nonexistent", map[string]any{})
	if resp.StatusCode != 404 {
		t.Errorf("status = %d, want 404", resp.StatusCode)
	}
}

func TestREST_RunPipeline(t *testing.T) {
	srv, _ := newRESTTestServer(t, true)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/run_pipeline", map[string]any{
		"stages": []any{
			[]any{"printf", "hello\nworld\n"},
			[]any{"grep", "world"},
		},
	})
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	if out["stdout"] != "world\n" {
		t.Errorf("stdout = %v, want %q", out["stdout"], "world\n")
	}
}

func TestREST_RunPipelineRejectedWhenWriteFalse(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/tools/run_pipeline", map[string]any{
		"stages": []any{[]any{"printf", "x"}},
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403", resp.StatusCode)
	}
}

func TestREST_MetricsQuery(t *testing.T) {
	srv, st := newRESTTestServer(t, false)
	defer srv.Close()

	now := time.Now().UTC()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "cpu_pct", Timestamp: now.Add(-time.Minute), Value: 55, Labels: map[string]string{"core": "0"}},
	}); err != nil {
		t.Fatal(err)
	}

	resp := doJSON(t, "GET", srv.URL+"/api/v1/metrics/cpu_pct?from=1h&label.core=0", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	points := out["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("expected 1 point, got %d: %+v", len(points), points)
	}
	p := points[0].(map[string]any)
	if p["value"] != 55.0 {
		t.Errorf("value = %v, want 55", p["value"])
	}
}

func TestREST_MetricsDump(t *testing.T) {
	srv, st := newRESTTestServer(t, false)
	defer srv.Close()

	now := time.Now().UTC()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "cpu_pct", Timestamp: now.Add(-time.Minute), Value: 10},
		{Metric: "mem_pct", Timestamp: now.Add(-time.Minute), Value: 20},
	}); err != nil {
		t.Fatal(err)
	}

	resp := doJSON(t, "GET", srv.URL+"/api/v1/metrics?from=1h", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	out := decodeJSON(t, resp)
	metrics := out["metrics"].(map[string]any)
	if len(metrics) != 2 {
		t.Fatalf("expected 2 metrics, got %d: %+v", len(metrics), metrics)
	}
}
