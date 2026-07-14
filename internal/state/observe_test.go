package state

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// stubDiscover stands in for the config_discover module (which shells out to
// systemctl) so Observe can be tested against canned discovery results.
type stubDiscover struct{ files []map[string]any }

func (s stubDiscover) Name() string                { return "config_discover" }
func (s stubDiscover) Description() string         { return "" }
func (s stubDiscover) InputSchema() map[string]any { return map[string]any{} }
func (s stubDiscover) Writes() bool                { return false }
func (s stubDiscover) Run(_ context.Context, _ map[string]any, _ bool) (modules.Result, error) {
	return modules.Result{Data: map[string]any{"services": []any{}, "config_files": s.files}}, nil
}

func TestObserve(t *testing.T) {
	dir := t.TempDir()
	kv := filepath.Join(dir, "svc")
	os.WriteFile(kv, []byte("FOO=bar\nBAZ=1\n"), 0o644)
	raw := filepath.Join(dir, "nginx.conf")
	os.WriteFile(raw, []byte("server { listen 80; }\n"), 0o644)

	r := modules.NewRegistry()
	_ = r.Register(modules.NewConfig())
	_ = r.Register(stubDiscover{files: []map[string]any{
		{"path": kv, "format": "keyvalue", "separator": "="},
		{"path": raw, "format": ""}, // no codec → hash reference
	}})

	obs, err := Observe(context.Background(), r, time.Unix(0, 0).UTC())
	if err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(obs.Config) != 2 {
		t.Fatalf("expected 2 config resources, got %d", len(obs.Config))
	}
	// sorted by path: nginx.conf before svc
	nginx, svc := obs.Config[0], obs.Config[1]
	if nginx.Path != raw || nginx.Values != nil || nginx.SHA256 == "" || nginx.Size == 0 {
		t.Errorf("raw resource should be a hash reference, got %+v", nginx)
	}
	if svc.Path != kv || svc.Values["FOO"] != "bar" || svc.Values["BAZ"] != "1" {
		t.Errorf("keyvalue resource should be structured, got %+v", svc)
	}
}
