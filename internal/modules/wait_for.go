package modules

import (
	"context"
	"fmt"
	"net"
	"os"
	"time"
)

// DialFunc opens a TCP connection to addr, returning immediately (without
// blocking beyond timeout) whether it succeeded. Injectable for testing
// (real implementation wraps net.DialTimeout).
type DialFunc func(network, addr string, timeout time.Duration) error

func defaultDial(network, addr string, timeout time.Duration) error {
	conn, err := net.DialTimeout(network, addr, timeout)
	if err != nil {
		return err
	}
	return conn.Close()
}

// WaitFor blocks until a condition is met — a TCP port accepting
// connections, or a file existing (or the inverse: a port no longer
// accepting connections, or a file no longer existing) — mirroring
// ansible.builtin.wait_for. It is read-only: it never mutates system
// state, only observes it, so it is not write-gated.
type WaitFor struct {
	Dial  DialFunc
	Stat  func(string) error
	Sleep func(time.Duration)
}

// NewWaitFor returns a WaitFor module backed by real network dials and
// filesystem stats.
func NewWaitFor() *WaitFor {
	return &WaitFor{
		Dial:  defaultDial,
		Stat:  func(path string) error { _, err := os.Stat(path); return err },
		Sleep: time.Sleep,
	}
}

func (w *WaitFor) Name() string { return "wait_for" }

func (w *WaitFor) Description() string {
	return "" +
		"Block until a condition is met: either a TCP port accepts connections (state=started, " +
		"the default, when `port` is given) or stops accepting them (state=stopped), or a file " +
		"exists (state=present, when `path` is given instead of `port`) or doesn't " +
		"(state=absent). Polls every `sleep` seconds (default 1) until `timeout` seconds elapse " +
		"(default 300, capped at 600 here to bound how long a single tool call can block). " +
		"Read-only — it never changes system state, only observes it, so it does not require " +
		"write:true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.wait_for. Same host/port/path/state/timeout/delay/sleep " +
		"semantics (a focused subset — Ansible also supports regex content matching inside the " +
		"file and searching for a string in the port's banner, not implemented here).\n" +
		"- Chef: no single built-in resource; typically a custom resource polling in a loop, or " +
		"the community 'wait_for_port'-style helpers.\n" +
		"- Puppet: no core equivalent; typically handled by an external orchestration tool " +
		"rather than the Puppet run itself.\n" +
		"- Salt: no single built-in state; typically a custom module or an `cmd.run` loop.\n" +
		"- Terraform: the `time_sleep` resource (fixed delay only, no actual condition-polling) " +
		"or a provisioner script loop."
}

func (w *WaitFor) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"host":    stringProp(`Host to connect to when checking a port. Default "127.0.0.1".`),
		"port":    stringProp("TCP port to wait for. Mutually exclusive with path."),
		"path":    stringProp("File path to wait for. Mutually exclusive with port."),
		"state":   stringEnumProp(`Condition to wait for. Default "started".`, "started", "stopped", "present", "absent"),
		"delay":   stringProp(`Seconds to wait before the first check. Default "0".`),
		"timeout": stringProp(`Maximum seconds to wait before failing. Default "300", capped at 600.`),
		"sleep":   stringProp(`Seconds between checks. Default "1".`),
	})
}

func (w *WaitFor) Writes() bool { return false }

func (w *WaitFor) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	host, err := stringParam(params, "host", false, "127.0.0.1")
	if err != nil {
		return Result{}, err
	}
	port, err := stringParam(params, "port", false, "")
	if err != nil {
		return Result{}, err
	}
	path, err := stringParam(params, "path", false, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "started")
	if err != nil {
		return Result{}, err
	}
	delay, err := intParam(params, "delay", 0)
	if err != nil {
		return Result{}, err
	}
	timeoutSec, err := intParam(params, "timeout", 300)
	if err != nil {
		return Result{}, err
	}
	sleepSec, err := intParam(params, "sleep", 1)
	if err != nil {
		return Result{}, err
	}

	if (port == "") == (path == "") {
		return Result{}, fmt.Errorf("wait_for: exactly one of port or path must be given")
	}
	switch state {
	case "started", "stopped":
		if port == "" {
			return Result{}, fmt.Errorf("wait_for: state %q requires port", state)
		}
	case "present", "absent":
		if path == "" {
			return Result{}, fmt.Errorf("wait_for: state %q requires path", state)
		}
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want started|stopped|present|absent)", state)
	}
	if timeoutSec > 600 {
		timeoutSec = 600
	}
	if sleepSec <= 0 {
		sleepSec = 1
	}

	if dryRun {
		return Result{Changed: false, Msg: "would wait for condition (dry run)", Data: map[string]any{"state": state}}, nil
	}

	if delay > 0 {
		w.Sleep(time.Duration(delay) * time.Second)
	}

	deadline := time.Now().Add(time.Duration(timeoutSec) * time.Second)
	for {
		met, checkErr := w.conditionMet(host, port, path, state)
		if checkErr != nil {
			return Result{}, checkErr
		}
		if met {
			return Result{Changed: false, Msg: "condition met", Data: map[string]any{"state": state}}, nil
		}
		if time.Now().After(deadline) {
			return Result{}, fmt.Errorf("wait_for: timed out after %ds waiting for state=%s", timeoutSec, state)
		}
		select {
		case <-ctx.Done():
			return Result{}, ctx.Err()
		default:
		}
		w.Sleep(time.Duration(sleepSec) * time.Second)
	}
}

func (w *WaitFor) conditionMet(host, port, path, state string) (bool, error) {
	switch state {
	case "started":
		err := w.Dial("tcp", net.JoinHostPort(host, port), 5*time.Second)
		return err == nil, nil
	case "stopped":
		err := w.Dial("tcp", net.JoinHostPort(host, port), 5*time.Second)
		return err != nil, nil
	case "present":
		return w.Stat(path) == nil, nil
	case "absent":
		return w.Stat(path) != nil, nil
	}
	return false, fmt.Errorf("wait_for: unreachable state %q", state)
}
