// Package audit provides structured, one-JSON-line-per-call audit logging
// for every tool/module/task dispatch. Writing to stderr is deliberate: when
// running under systemd (the packaged deployment), each line is captured
// into the journal automatically and, being valid JSON, is directly
// consumable via `journalctl -u agentic-mcp -o cat | jq` without needing the
// native systemd journal protocol or an extra dependency.
package audit

import (
	"encoding/json"
	"io"
	"strings"
	"sync"
	"time"
)

// Entry is one audit record: who called what, with what parameters, and
// what happened.
type Entry struct {
	Time       time.Time      `json:"time"`
	Identity   string         `json:"identity"`
	Tool       string         `json:"tool"`
	Write      bool           `json:"write"`
	Changed    bool           `json:"changed,omitempty"`
	Params     map[string]any `json:"params,omitempty"`
	Error      string         `json:"error,omitempty"`
	DurationMS int64          `json:"duration_ms"`
}

// Logger writes Entry records as newline-delimited JSON to an underlying
// writer, safe for concurrent use. A nil *Logger is valid and logs nothing
// (Log/LogCall are no-ops), so call sites don't need to branch on whether
// auditing is configured.
type Logger struct {
	mu  sync.Mutex
	out io.Writer
}

// New returns a Logger writing to w.
func New(w io.Writer) *Logger {
	return &Logger{out: w}
}

// Log writes one entry as a JSON line. Parameter values whose key looks
// like it might hold a secret (contains "password", "secret", or "token",
// case-insensitively) are redacted before writing.
func (l *Logger) Log(e Entry) {
	if l == nil {
		return
	}
	e.Params = redactParams(e.Params)
	data, err := json.Marshal(e)
	if err != nil {
		return
	}
	data = append(data, '\n')

	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.out.Write(data)
}

// LogCall is a convenience for the common case: log the outcome of a
// dispatched tool call given its start time, whether it changed state, and
// any error.
func (l *Logger) LogCall(identity, tool string, writes, changed bool, params map[string]any, start time.Time, callErr error) {
	if l == nil {
		return
	}
	e := Entry{
		Time:       start,
		Identity:   identity,
		Tool:       tool,
		Write:      writes,
		Changed:    changed,
		Params:     params,
		DurationMS: time.Since(start).Milliseconds(),
	}
	if callErr != nil {
		e.Error = callErr.Error()
	}
	l.Log(e)
}

var sensitiveSubstrings = []string{"password", "secret", "token"}

// redactParams returns a copy of params with values under sensitive-looking
// keys replaced by "[REDACTED]".
func redactParams(params map[string]any) map[string]any {
	if params == nil {
		return nil
	}
	out := make(map[string]any, len(params))
	for k, v := range params {
		lk := strings.ToLower(k)
		redacted := false
		for _, s := range sensitiveSubstrings {
			if strings.Contains(lk, s) {
				redacted = true
				break
			}
		}
		if redacted {
			out[k] = "[REDACTED]"
		} else {
			out[k] = v
		}
	}
	return out
}
