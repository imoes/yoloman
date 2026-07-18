package starmod

import (
	"os"
	"testing"
)

// mockCaps is a Capabilities whose Run returns a canned result, so a check
// module can be exercised against real plugin output without spawning a
// process. Every other capability is inert.
type mockCaps struct {
	stdout string
	rc     int
}

func (m mockCaps) CheckMode() bool { return false }
func (m mockCaps) Run(_ []string, _ bool, _ []int) (RunResult, error) {
	return RunResult{RC: m.rc, Stdout: m.stdout}, nil
}
func (m mockCaps) FileRead(string) (string, error)                { return "", nil }
func (m mockCaps) FileWrite(string, string, string) (bool, error) { return false, nil }
func (m mockCaps) FileExists(string) (bool, error)                { return false, nil }
func (m mockCaps) Stat(string) (map[string]any, error)            { return nil, nil }
func (m mockCaps) Facts() (map[string]any, error)                 { return map[string]any{}, nil }
func (m mockCaps) Probe(string, map[string]any) (map[string]any, error) {
	return map[string]any{"error": ""}, nil
}

func loadCheckPlugin(t *testing.T) []byte {
	t.Helper()
	src, err := os.ReadFile("../../configs/checks.d/check_plugin.star")
	if err != nil {
		t.Fatalf("read check_plugin.star: %v", err)
	}
	return src
}

// runCheck executes check_plugin.star with a canned command output and returns
// the verdict data map.
func runCheck(t *testing.T, src []byte, stdout string, rc int, params map[string]any) map[string]any {
	t.Helper()
	if params == nil {
		params = map[string]any{}
	}
	params["command"] = []any{"/bin/true"}
	res, err := Execute("check_plugin.star", src, params, mockCaps{stdout: stdout, rc: rc}, Options{})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	data, ok := res.Data.(map[string]any)
	if !ok {
		t.Fatalf("data is %T, want map", res.Data)
	}
	return data
}

func wantState(t *testing.T, data map[string]any, want string) {
	t.Helper()
	if got := data["state"]; got != want {
		t.Errorf("state = %v, want %v (details: %v)", got, want, data["details"])
	}
}

func wantMetric(t *testing.T, data map[string]any, key string, want float64) {
	t.Helper()
	metrics, ok := data["metrics"].(map[string]any)
	if !ok {
		t.Fatalf("metrics is %T, want map", data["metrics"])
	}
	v, present := metrics[key]
	if !present {
		t.Fatalf("metric %q missing (have: %v)", key, metrics)
	}
	got := toFloat(t, v)
	if got != want {
		t.Errorf("metric %q = %v, want %v", key, got, want)
	}
}

func toFloat(t *testing.T, v any) float64 {
	t.Helper()
	switch n := v.(type) {
	case float64:
		return n
	case int64:
		return float64(n)
	case int:
		return float64(n)
	default:
		t.Fatalf("metric value is %T, want number", v)
		return 0
	}
}

func TestCheckPlugin_DetectsNagiosFromExitCode(t *testing.T) {
	src := loadCheckPlugin(t)
	// Nagios: state comes from the exit code, not the text.
	data := runCheck(t, src, "CRITICAL - load high | load1=5.2;4;10 load5=3.1;;", 2, nil)
	wantState(t, data, "CRIT")
	wantMetric(t, data, "load1", 5.2)
	wantMetric(t, data, "load5", 3.1)

	ok := runCheck(t, src, "OK - all fine | procs=42", 0, nil)
	wantState(t, ok, "OK")
	wantMetric(t, ok, "procs", 42)
}

func TestCheckPlugin_DetectsCheckmkLocal(t *testing.T) {
	src := loadCheckPlugin(t)
	// Two services on stdout, script exits 0 — the state lives in the lines.
	out := "0 mydisk size=5;;;; all good\n2 \"my raid\" health=0 degraded array"
	disk := runCheck(t, src, out, 0, map[string]any{"item": "mydisk"})
	wantState(t, disk, "OK")
	wantMetric(t, disk, "size", 5)

	raid := runCheck(t, src, out, 0, map[string]any{"item": "my raid"})
	wantState(t, raid, "CRIT")
	wantMetric(t, raid, "health", 0)
}

func TestCheckPlugin_LocalDashPerf(t *testing.T) {
	src := loadCheckPlugin(t)
	data := runCheck(t, src, "1 backup - last run too old", 0, map[string]any{"item": "backup"})
	wantState(t, data, "WARN")
	if m := data["metrics"].(map[string]any); len(m) != 0 {
		t.Errorf("expected no metrics for '-' perfdata, got %v", m)
	}
}

func TestCheckPlugin_NagiosNotMisreadAsLocal(t *testing.T) {
	src := loadCheckPlugin(t)
	// Starts with "2" like a local status, but the 3rd field isn't perfdata —
	// must fall back to Nagios (state from rc=0 → OK, not CRIT).
	data := runCheck(t, src, "2 processes running | procs=2", 0, nil)
	wantState(t, data, "OK")
	wantMetric(t, data, "procs", 2)
}

func TestCheckPlugin_DetectsAgentSections(t *testing.T) {
	src := loadCheckPlugin(t)
	out := "<<<check_mk>>>\nVersion: 2.1.0\n<<<df>>>\n/dev/sda1 / 100 50 50 50% /"
	data := runCheck(t, src, out, 0, nil)
	wantState(t, data, "OK")
	wantMetric(t, data, "sections", 2)
}

func TestCheckPlugin_ForceFormatOverridesDetection(t *testing.T) {
	src := loadCheckPlugin(t)
	// Local-looking output, but forced to nagios → state from rc, whole line
	// kept as the summary (no per-line parse).
	data := runCheck(t, src, "0 svc metric=1 fine", 2, map[string]any{"force_format": "nagios"})
	wantState(t, data, "CRIT")
}

func TestCheckPlugin_DiscoveryLocalPerLine(t *testing.T) {
	src := loadCheckPlugin(t)
	out := "0 disk1 used=10 ok\n0 disk2 used=20 ok"
	data := runCheck(t, src, out, 0, map[string]any{"_discover": true})
	disc, ok := data["discovery"].([]any)
	if !ok {
		t.Fatalf("discovery is %T, want list", data["discovery"])
	}
	if len(disc) != 2 {
		t.Fatalf("discovered %d items, want 2", len(disc))
	}
}
