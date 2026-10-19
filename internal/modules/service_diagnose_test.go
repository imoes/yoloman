package modules

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
)

func TestServiceDiagnoseIsReadOnlyAndReturnsAContractDocument(t *testing.T) {
	m := &ServiceDiagnose{
		Runner: func(_ context.Context, name string, args ...string) ([]byte, error) {
			switch name {
			case "systemctl":
				return []byte("LoadState=loaded\nActiveState=failed\nResult=exit-code\nExecMainStatus=203\n" +
					"ExecStart={ path=/usr/local/bin/gone ; argv[]=/usr/local/bin/gone }\nInvocationID=i1\n"), nil
			case "journalctl":
				return []byte(`{"__CURSOR":"c1","MESSAGE":"probe.service: Failed to locate executable /usr/local/bin/gone: No such file or directory","INVOCATION_ID":"i1","__REALTIME_TIMESTAMP":"1792246839000000"}` + "\n"), nil
			}
			return nil, errors.New("unexpected " + name)
		},
		Stat: func(string) (os.FileInfo, error) { return nil, os.ErrNotExist },
		Now:  func() time.Time { return time.Date(2026, 10, 17, 14, 0, 0, 0, time.UTC) },
		Host: func() (string, error) { return "e2e-deb-1", nil },
	}
	if m.Writes() {
		t.Fatal("service_diagnose must be read-only")
	}
	res, err := m.Run(context.Background(), map[string]any{"name": "probe", "include_snapshot": true}, false)
	if err != nil {
		t.Fatal(err)
	}
	data := res.Data.(map[string]any)
	d := data["diagnosis"].(*diagnosis.Diagnosis)
	if res.Changed || d.Findings[0].RuleID != "svc.image_missing" || d.Findings[0].Certainty != diagnosis.Proven {
		t.Fatalf("%+v", d.Findings)
	}
	if !strings.Contains(res.Msg, "/usr/local/bin/gone") || data["snapshot"] == nil {
		t.Fatalf("msg %q / snapshot %v", res.Msg, data["snapshot"] != nil)
	}
}

func TestServiceDiagnoseRefusesWhatIsNoUnitName(t *testing.T) {
	for _, n := range []string{"", "a b", "../etc/passwd"} {
		if _, err := NewServiceDiagnose().Run(context.Background(), map[string]any{"name": n}, false); err == nil {
			t.Errorf("%q accepted", n)
		}
	}
}

func TestIncidentsForUnitMatchesByKernelComm(t *testing.T) {
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	all := []diagnosis.Incident{
		{Kind: diagnosis.IncidentOOMKill, At: now.Add(-3 * time.Minute), PID: 10, Image: "my-long-daemon", Source: "ebpf"},
		{Kind: diagnosis.IncidentOOMKill, At: now.Add(-1 * time.Minute), PID: 11, Image: "my-long-daemon", Source: "ebpf"},
		{Kind: diagnosis.IncidentFatalSignal, At: now.Add(-2 * time.Minute), PID: 12, Image: "other", Detail: "SIGSEGV", Source: "ebpf"},
	}
	// The exec is /usr/bin/my-long-daemon-xyz; the kernel comm is the base name truncated to 15 → "my-long-daemon" (14),
	// here padded so truncation bites: base "my-long-daemonX..." → first 15 "my-long-daemonX". Use a name that truncates
	// to exactly what the ring stored.
	got := incidentsForUnit("/usr/bin/my-long-daemon", all) // base "my-long-daemon" (14 ch) == stored comm
	if len(got) != 2 {
		t.Fatalf("want 2 matches by comm, got %d: %+v", len(got), got)
	}
	if !got[0].At.After(got[1].At) {
		t.Fatalf("incidents must be newest first: %+v", got)
	}
	if n := len(incidentsForUnit("/usr/bin/other", all)); n != 1 {
		t.Fatalf("want 1 match for 'other', got %d", n)
	}
	if n := len(incidentsForUnit("", all)); n != 0 {
		t.Fatalf("empty exec path should match nothing, got %d", n)
	}
}

func TestExecCommTruncatesToFifteen(t *testing.T) {
	if c := execComm("/opt/app/averylongprocessname"); c != "averylongproces" {
		t.Fatalf("comm truncation: %q", c)
	}
	if c := execComm("/usr/sbin/nginx"); c != "nginx" {
		t.Fatalf("short comm: %q", c)
	}
}
