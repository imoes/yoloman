package audit

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestLog_WritesValidJSONLine(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	l.Log(Entry{Time: time.Unix(1700000000, 0), Identity: "token:service-token", Tool: "stat", Write: false})

	line := strings.TrimRight(buf.String(), "\n")
	var decoded Entry
	if err := json.Unmarshal([]byte(line), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v (line=%q)", err, line)
	}
	if decoded.Identity != "token:service-token" || decoded.Tool != "stat" {
		t.Errorf("unexpected decoded entry: %+v", decoded)
	}
	if !strings.HasSuffix(buf.String(), "\n") {
		t.Error("expected the entry to be newline-terminated")
	}
}

func TestLog_RedactsSensitiveParams(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	l.Log(Entry{
		Tool: "auth_login",
		Params: map[string]any{
			"username":    "alice",
			"password":    "hunter2",
			"api_token":   "abc123",
			"some_secret": "xyz",
		},
	})

	var decoded Entry
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if decoded.Params["username"] != "alice" {
		t.Errorf("expected username to survive unredacted, got %v", decoded.Params["username"])
	}
	if decoded.Params["password"] != "[REDACTED]" {
		t.Errorf("expected password redacted, got %v", decoded.Params["password"])
	}
	if decoded.Params["api_token"] != "[REDACTED]" {
		t.Errorf("expected api_token redacted, got %v", decoded.Params["api_token"])
	}
	if decoded.Params["some_secret"] != "[REDACTED]" {
		t.Errorf("expected some_secret redacted, got %v", decoded.Params["some_secret"])
	}
}

func TestLogCall_RecordsErrorAndDuration(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	start := time.Now().Add(-50 * time.Millisecond)
	l.LogCall("user:alice", "copy", true, true, map[string]any{"dest": "/tmp/x"}, start, errors.New("boom"))

	var decoded Entry
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if decoded.Error != "boom" {
		t.Errorf("error = %q, want boom", decoded.Error)
	}
	if decoded.DurationMS < 40 {
		t.Errorf("duration_ms = %d, want >= ~50", decoded.DurationMS)
	}
	if !decoded.Write || !decoded.Changed {
		t.Errorf("expected write=true changed=true, got %+v", decoded)
	}
}

func TestLogCall_NoErrorOmitsErrorField(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	l.LogCall("token:service-token", "stat", false, false, nil, time.Now(), nil)

	if strings.Contains(buf.String(), `"error"`) {
		t.Errorf("expected no error field for a successful call, got %q", buf.String())
	}
}

func TestNilLogger_IsNoOp(t *testing.T) {
	var l *Logger
	// Must not panic.
	l.Log(Entry{Tool: "x"})
	l.LogCall("token:service-token", "x", false, false, nil, time.Now(), nil)
}

func TestConcurrentLog_NoDataRace(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	done := make(chan struct{})
	for i := 0; i < 10; i++ {
		go func(i int) {
			l.Log(Entry{Tool: "concurrent"})
			done <- struct{}{}
		}(i)
	}
	for i := 0; i < 10; i++ {
		<-done
	}
	lines := strings.Count(buf.String(), "\n")
	if lines != 10 {
		t.Errorf("expected 10 log lines, got %d", lines)
	}
}
