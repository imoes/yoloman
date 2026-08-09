package modules

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// journalMaxLines caps how many entries a single call may pull, so a
// `journalctl -o json` over a huge journal can't blow up memory or the wire.
const journalMaxLines = 5000

// journalDefaultLines is used when the caller omits `lines`.
const journalDefaultLines = 200

// Journal reads the systemd journal (journald) via `journalctl -o json`,
// the read-only counterpart to the write-gated systemd module. There is no
// /proc source for journald, so — like service_facts — it shells out to the
// journalctl binary; Runner is injectable for testing. Read-only: it never
// mutates and always reports changed=false.
type Journal struct {
	Runner CommandRunner
}

// NewJournal returns a Journal module backed by the real journalctl.
func NewJournal() *Journal { return &Journal{Runner: defaultCommandRunner} }

func (m *Journal) Name() string { return "journal" }

func (m *Journal) Description() string {
	return "" +
		"Read the systemd journal (journald) via `journalctl -o json`, optionally filtered by " +
		"unit, priority, a time window, or a message pattern. Returns the most recent N entries " +
		"(newest last), each as {timestamp, unit, priority, message, pid, hostname}. Read-only " +
		"— it never writes and always reports changed=false. Use this to answer 'what has this " +
		"service been logging' / 'why did it fail' without shell access, as the Logs section of " +
		"the host-management page and as an MCP tool.\n\n" +
		"Parameters: lines (default 200, capped at 5000), unit (a systemd unit like \"nginx\"), " +
		"priority (0-7 or a name like \"err\"; shows that level and worse), since (any journalctl " +
		"time spec, e.g. \"2024-01-01 10:00\", \"-1h\", \"yesterday\"), boot (true = current boot " +
		"only), grep (a message regex).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: no first-class module; typically `ansible.builtin.command: journalctl ...` " +
		"then parse, or the community `syslog`/log-reading roles. This module makes it structured.\n" +
		"- Chef/Puppet/Salt: normally a `shell_out`/`cmd.run` around journalctl; none ship a " +
		"dedicated journald-reading resource.\n" +
		"- Terraform: not applicable — Terraform does not read live host logs."
}

func (m *Journal) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"lines": map[string]any{
			"type":        "integer",
			"description": fmt.Sprintf("How many of the most recent entries to return (default %d, capped at %d).", journalDefaultLines, journalMaxLines),
		},
		"unit":     stringProp(`Restrict to one systemd unit, e.g. "nginx" or "nginx.service".`),
		"priority": stringProp(`Restrict to this syslog priority and worse: 0-7 (emerg..debug) or a name like "err", "warning", "info".`),
		"since":    stringProp(`Only entries at/after this time. Any journalctl time spec: "2024-01-01 10:00", "-1h", "yesterday".`),
		"boot":     boolProp("When true, restrict to the current boot only (journalctl --boot).", false),
		"grep":     stringProp("Only entries whose MESSAGE matches this (journalctl --grep, a regex)."),
	})
}

func (m *Journal) Writes() bool { return false }

func (m *Journal) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	lines, err := intParam(params, "lines", journalDefaultLines)
	if err != nil {
		return Result{}, err
	}
	if lines <= 0 {
		lines = journalDefaultLines
	}
	if lines > journalMaxLines {
		lines = journalMaxLines
	}
	unit, err := stringParam(params, "unit", false, "")
	if err != nil {
		return Result{}, err
	}
	priority, err := stringParam(params, "priority", false, "")
	if err != nil {
		return Result{}, err
	}
	since, err := stringParam(params, "since", false, "")
	if err != nil {
		return Result{}, err
	}
	grep, err := stringParam(params, "grep", false, "")
	if err != nil {
		return Result{}, err
	}
	boot, err := boolParam(params, "boot", false)
	if err != nil {
		return Result{}, err
	}

	args := []string{"--no-pager", "-o", "json", "-n", strconv.Itoa(lines)}
	if unit != "" {
		args = append(args, "--unit="+unit)
	}
	if priority != "" {
		args = append(args, "--priority="+priority)
	}
	if since != "" {
		args = append(args, "--since="+since)
	}
	if grep != "" {
		args = append(args, "--grep="+grep)
	}
	if boot {
		args = append(args, "--boot")
	}

	out, err := m.Runner(ctx, "journalctl", args...)
	if err != nil {
		return Result{}, fmt.Errorf("journal: running journalctl: %w", err)
	}
	entries := parseJournalJSON(out)
	return Result{Changed: false, Data: map[string]any{"entries": entries, "count": len(entries)}}, nil
}

// parseJournalJSON parses the JSON-lines output of `journalctl -o json`
// (one JSON object per line, oldest first) into friendly entries. Fields that
// journald may render as a byte array (binary MESSAGE) rather than a string
// are coerced back to text.
func parseJournalJSON(out []byte) []map[string]any {
	entries := []map[string]any{}
	scanner := bufio.NewScanner(bytes.NewReader(out))
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var raw map[string]any
		if err := json.Unmarshal(line, &raw); err != nil {
			continue // skip a malformed line rather than fail the whole read
		}
		entries = append(entries, map[string]any{
			"timestamp": journalTimestamp(raw["__REALTIME_TIMESTAMP"]),
			"unit":      journalUnit(raw),
			"priority":  journalString(raw["PRIORITY"]),
			"message":   journalMessage(raw["MESSAGE"]),
			"pid":       journalString(raw["_PID"]),
			"hostname":  journalString(raw["_HOSTNAME"]),
		})
	}
	return entries
}

// journalTimestamp converts journald's __REALTIME_TIMESTAMP (microseconds
// since the epoch, as a string) into an RFC3339 string; falls back to the
// raw value if it can't be parsed.
func journalTimestamp(v any) string {
	s := journalString(v)
	if s == "" {
		return ""
	}
	usec, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return s
	}
	return time.Unix(usec/1_000_000, (usec%1_000_000)*1000).UTC().Format(time.RFC3339)
}

// journalUnit prefers the real systemd unit, falling back to the syslog
// identifier for entries not associated with a unit (kernel, session, …).
func journalUnit(raw map[string]any) string {
	if u := journalString(raw["_SYSTEMD_UNIT"]); u != "" {
		return u
	}
	return journalString(raw["SYSLOG_IDENTIFIER"])
}

// journalString renders a journal field as a string. journald fields are
// usually strings but may be numbers; anything else yields "".
func journalString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	default:
		return ""
	}
}

// journalMessage handles MESSAGE, which journald renders as a string for text
// and as an array of byte values (numbers) for binary/non-UTF-8 content.
func journalMessage(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []any:
		var b strings.Builder
		for _, e := range t {
			if n, ok := e.(float64); ok {
				b.WriteByte(byte(int(n)))
			}
		}
		return b.String()
	default:
		return ""
	}
}
