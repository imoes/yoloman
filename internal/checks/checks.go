// Package checks runs Nagios/CheckMK-compatible plugin executables and
// parses their standard output contract, so any existing check_* plugin
// (or a custom script following the same convention) becomes an MCP/REST
// tool with no adapter code beyond a description.
//
// Plugin contract (the de facto Nagios Plugin API, also used by CheckMK's
// local/MRPE checks): exit code 0/1/2/3 means OK/WARNING/CRITICAL/UNKNOWN;
// stdout's first line is "<message>[ | <perfdata>]"; any further lines are
// additional "long output" (optionally with more perfdata after a "|" on
// those lines too, which this v1 parser does not yet extract separately).
package checks

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

// Status is a plugin's overall result, derived from its exit code.
type Status string

const (
	StatusOK       Status = "OK"
	StatusWarning  Status = "WARNING"
	StatusCritical Status = "CRITICAL"
	StatusUnknown  Status = "UNKNOWN"
)

// StatusFromExitCode maps a plugin's process exit code to a Status,
// following the Nagios Plugin API (0/1/2/3 = OK/WARNING/CRITICAL/UNKNOWN;
// anything else is treated as UNKNOWN too).
func StatusFromExitCode(code int) Status {
	switch code {
	case 0:
		return StatusOK
	case 1:
		return StatusWarning
	case 2:
		return StatusCritical
	default:
		return StatusUnknown
	}
}

// PerfDatum is one performance-data point from a plugin's output, in the
// Nagios Plugin API's "label=value[;warn[;crit[;min[;max]]]]" format. Only
// Label and Value are guaranteed to be present.
type PerfDatum struct {
	Label string `json:"label"`
	Value string `json:"value"`
	Warn  string `json:"warn,omitempty"`
	Crit  string `json:"crit,omitempty"`
	Min   string `json:"min,omitempty"`
	Max   string `json:"max,omitempty"`
}

// Result is a parsed check outcome.
type Result struct {
	Status     Status      `json:"status"`
	Message    string      `json:"message"`
	LongOutput string      `json:"long_output,omitempty"`
	Perfdata   []PerfDatum `json:"perfdata,omitempty"`
	ExitCode   int         `json:"exit_code"`
}

// ParseOutput parses a plugin's captured stdout given its process exit
// code, per the Nagios Plugin API contract described in the package doc.
func ParseOutput(exitCode int, stdout string) Result {
	res := Result{Status: StatusFromExitCode(exitCode), ExitCode: exitCode}

	lines := strings.Split(stdout, "\n")
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) == 0 {
		return res
	}

	message, perfStr, hasPerf := strings.Cut(lines[0], "|")
	res.Message = strings.TrimSpace(message)
	if hasPerf {
		res.Perfdata = parsePerfdata(perfStr)
	}
	if len(lines) > 1 {
		res.LongOutput = strings.Join(lines[1:], "\n")
	}
	return res
}

// parsePerfdata parses a "label1=value1;w;c label2=value2 ..." perfdata
// string into individual PerfDatum entries.
func parsePerfdata(s string) []PerfDatum {
	var out []PerfDatum
	for _, field := range strings.Fields(s) {
		label, rest, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		parts := strings.Split(rest, ";")
		pd := PerfDatum{Label: label, Value: parts[0]}
		if len(parts) > 1 {
			pd.Warn = parts[1]
		}
		if len(parts) > 2 {
			pd.Crit = parts[2]
		}
		if len(parts) > 3 {
			pd.Min = parts[3]
		}
		if len(parts) > 4 {
			pd.Max = parts[4]
		}
		out = append(out, pd)
	}
	return out
}

// ExecFunc runs argv and returns its captured combined stdout/stderr and
// exit code. A non-zero exit code is ordinary plugin data (see the package
// doc), not a Go error — only a failure to start the process at all is.
type ExecFunc func(ctx context.Context, argv []string, timeout time.Duration) (output string, exitCode int, err error)

// DefaultExec runs argv via os/exec, combining stdout and stderr (most
// check plugins write their one-line result to stdout, but combining is
// more forgiving of plugins that don't).
func DefaultExec(ctx context.Context, argv []string, timeout time.Duration) (string, int, error) {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return out.String(), exitErr.ExitCode(), nil
		}
		return "", 0, err
	}
	return out.String(), 0, nil
}

// Run executes argv via exec and parses its output into a Result.
func Run(ctx context.Context, exec ExecFunc, argv []string, timeout time.Duration) (Result, error) {
	output, exitCode, err := exec(ctx, argv, timeout)
	if err != nil {
		return Result{}, err
	}
	return ParseOutput(exitCode, output), nil
}

// RunDefault is Run backed by DefaultExec — the real, non-test entry point.
func RunDefault(ctx context.Context, argv []string, timeout time.Duration) (Result, error) {
	return Run(ctx, DefaultExec, argv, timeout)
}
