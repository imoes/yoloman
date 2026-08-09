package modules

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
)

func TestJournal_ParsesJSONLines(t *testing.T) {
	// Two journalctl -o json lines: a normal string MESSAGE with a unit, and
	// a binary MESSAGE rendered as a byte array without a unit.
	canned := `{"__REALTIME_TIMESTAMP":"1700000000000000","_SYSTEMD_UNIT":"nginx.service","PRIORITY":"6","MESSAGE":"started","_PID":"42","_HOSTNAME":"h1"}` + "\n" +
		`{"__REALTIME_TIMESTAMP":"1700000001000000","SYSLOG_IDENTIFIER":"kernel","PRIORITY":"3","MESSAGE":[104,105],"_HOSTNAME":"h1"}` + "\n"

	var gotArgs []string
	m := &Journal{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name != "journalctl" {
			t.Errorf("expected journalctl, got %q", name)
		}
		gotArgs = args
		return []byte(canned), nil
	}}

	res, err := m.Run(context.Background(), map[string]any{"lines": 50, "unit": "nginx", "priority": "6"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["count"] != 2 {
		t.Fatalf("count = %v, want 2", data["count"])
	}
	entries := data["entries"].([]map[string]any)

	if entries[0]["unit"] != "nginx.service" || entries[0]["message"] != "started" || entries[0]["pid"] != "42" {
		t.Errorf("unexpected first entry: %+v", entries[0])
	}
	if !strings.HasPrefix(entries[0]["timestamp"].(string), "2023-11-14T") {
		t.Errorf("timestamp not RFC3339-ish: %v", entries[0]["timestamp"])
	}
	// binary MESSAGE [104,105] -> "hi"; unit falls back to SYSLOG_IDENTIFIER.
	if entries[1]["message"] != "hi" || entries[1]["unit"] != "kernel" {
		t.Errorf("unexpected second entry: %+v", entries[1])
	}

	// Args forwarded: -o json, -n 50, --unit=nginx, --priority=6.
	joined := strings.Join(gotArgs, " ")
	for _, want := range []string{"-o json", "-n 50", "--unit=nginx", "--priority=6"} {
		if !strings.Contains(joined, want) {
			t.Errorf("args %q missing %q", joined, want)
		}
	}
}

func TestJournal_LinesDefaultAndCap(t *testing.T) {
	capture := func(params map[string]any) string {
		var n string
		m := &Journal{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			for i, a := range args {
				if a == "-n" && i+1 < len(args) {
					n = args[i+1]
				}
			}
			return []byte(""), nil
		}}
		if _, err := m.Run(context.Background(), params, false); err != nil {
			t.Fatalf("Run: %v", err)
		}
		return n
	}

	if got := capture(nil); got != strconv.Itoa(journalDefaultLines) {
		t.Errorf("default -n = %q, want %d", got, journalDefaultLines)
	}
	if got := capture(map[string]any{"lines": 999999}); got != strconv.Itoa(journalMaxLines) {
		t.Errorf("capped -n = %q, want %d", got, journalMaxLines)
	}
	if got := capture(map[string]any{"lines": 0}); got != strconv.Itoa(journalDefaultLines) {
		t.Errorf("zero -n = %q, want default %d", got, journalDefaultLines)
	}
}

func TestJournal_RunnerError(t *testing.T) {
	m := &Journal{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("journalctl: command not found")
	}}
	if _, err := m.Run(context.Background(), nil, false); err == nil {
		t.Fatal("expected error when journalctl is missing")
	}
}

func TestJournal_IsReadOnly(t *testing.T) {
	if NewJournal().Writes() {
		t.Error("journal must be read-only")
	}
}
