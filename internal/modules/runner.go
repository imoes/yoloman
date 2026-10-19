package modules

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// headlessEnv is the child-process environment for every shelled-out command:
// the daemon runs under systemd with no controlling TTY, so apt/dpkg's debconf
// must never try an interactive frontend (Dialog/Readline/Teletype all need a
// tty and fail with "TERM is not set", aborting an otherwise-fine package
// install). Forcing DEBIAN_FRONTEND=noninteractive makes debconf use defaults;
// harmless for non-apt commands (dnf/systemctl/getent ignore it).
func headlessEnv() []string {
	return append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
}

// CommandRunner executes name with args and returns its stdout. It exists so
// modules that must shell out (service_facts, package_facts, getent — there
// is no pure-/proc source for systemd/dpkg/NSS state) can be tested with a
// canned runner instead of depending on the real host's tools.
//
// On failure the returned error's message includes the command's actual
// stderr output, not just the bare exit status — an exit code alone
// ("exit status 1") tells a caller (especially an AI deciding what to do
// next) that something failed but nothing about why; the real reason
// ("Unit foo.service not found", "Unable to locate package bar") is what
// makes the failure actionable. See defaultCommandRunner.
type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

// defaultCommandRunner runs the real command via os/exec, capturing stdout
// for the success path (parsed by callers like dpkg-query/systemctl output
// parsing) while enriching a failure's error with the command's stderr.
func defaultCommandRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	return runCapped(ctx, nil, name, args...)
}

// CommandRunnerWithStdin is CommandRunner's counterpart for the handful of
// tools (dpkg --set-selections, and no others so far in this codebase) that
// only accept input via stdin, with no file-argument alternative.
type CommandRunnerWithStdin func(ctx context.Context, stdin string, name string, args ...string) ([]byte, error)

// defaultCommandRunnerWithStdin runs the real command via os/exec, feeding
// stdin to it and applying the same stderr-enriched error handling as
// defaultCommandRunner.
func defaultCommandRunnerWithStdin(ctx context.Context, stdin string, name string, args ...string) ([]byte, error) {
	return runCapped(ctx, strings.NewReader(stdin), name, args...)
}

// maxCommandOutput bounds what one shelled-out command may write before it is stopped. Measured 2026-10-11:
// hylafax-server's postinst runs faxsetup, which ignores DEBIAN_FRONTEND and re-asks "Area code []?" forever on an
// empty stdin — more than 64 MB in seconds, buffered whole by cmd.Output(), until the test host died without a log
// line. Normal output (a dpkg-query of thousands of packages) is a few MB; 32 MiB is far above it.
var maxCommandOutput = 32 << 20

// cappedBuffer keeps up to `limit` bytes plus the last bytes written (for the error), and cancels the command when
// the limit is passed.
type cappedBuffer struct {
	limit    int
	buf      bytes.Buffer
	tail     []byte
	exceeded bool
	cancel   context.CancelFunc
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.buf.Len()+len(p) > c.limit {
		if !c.exceeded {
			c.exceeded = true
			c.cancel()
		}
	} else {
		c.buf.Write(p)
	}
	c.tail = append(c.tail, p...)
	if len(c.tail) > 2048 {
		c.tail = c.tail[len(c.tail)-2048:]
	}
	return len(p), nil
}

// runCapped runs the command headless with bounded stdout/stderr capture. A command that writes more than
// maxCommandOutput is stopped, and the error names that and quotes its last output — the prompt it was looping on
// is the actionable reason, not "signal: killed".
func runCapped(ctx context.Context, stdin io.Reader, name string, args ...string) ([]byte, error) {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(runCtx, name, args...)
	cmd.Env = headlessEnv()
	cmd.Stdin = stdin
	// Stop the whole process GROUP, not just the direct child: apt killed alone left hylafax's postinst (faxsetup)
	// looping on, holding the output pipe open, and Wait never returned. WaitDelay bounds the wait for such pipes.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	stdout := &cappedBuffer{limit: maxCommandOutput, cancel: cancel}
	stderr := &cappedBuffer{limit: maxCommandOutput, cancel: cancel}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	out := stdout.buf.Bytes()
	cmdLine := strings.TrimSpace(name + " " + strings.Join(args, " "))
	if stdout.exceeded || stderr.exceeded {
		last := strings.TrimSpace(string(stdout.tail) + string(stderr.tail))
		if len(last) > 300 {
			last = last[len(last)-300:]
		}
		return out, fmt.Errorf("%s: produced more than %d MiB of output and was stopped (a prompt loop? the last "+
			"output: %q)", cmdLine, maxCommandOutput>>20, last)
	}
	if err != nil {
		msg := strings.TrimSpace(stderr.buf.String())
		// The CAUSE is often on stdout: dpkg prints a maintainer script's failure there ("ln: failed to create
		// symbolic link '/etc/resolv.conf': Device or resource busy", "dpkg: error processing package resolvconf"),
		// and the error said only "E: Sub-process /usr/bin/dpkg returned an error code (1)" (measured in the
		// package e2e: whereami, ifupdown-ng, rdnssd). The lines that name a failure are added.
		if cause := causeLines(out, msg); cause != "" {
			msg = strings.TrimSpace(msg + "\n" + cause)
		}
		return out, wrapExitError(name, args, err, msg)
	}
	return out, nil
}

var causeLine = regexp.MustCompile(`(?i)\b(error|errors|failed|fail|cannot|can't|denied|no such|not found|unable)\b`)

// causeLines: up to 8 lines from the end of stdout that name a failure and are not already in stderr.
func causeLines(stdout []byte, stderr string) string {
	lines := strings.Split(strings.TrimRight(string(stdout), "\n"), "\n")
	if len(lines) > 200 {
		lines = lines[len(lines)-200:]
	}
	var picked []string
	for _, ln := range lines {
		ln = strings.TrimSpace(ln)
		if ln != "" && causeLine.MatchString(ln) && !strings.Contains(stderr, ln) {
			picked = append(picked, ln)
		}
	}
	if len(picked) > 8 {
		picked = picked[len(picked)-8:]
	}
	return strings.Join(picked, "\n")
}

// wrapExitError enriches err (as returned by cmd.Output()/cmd.Run()) with
// the command's stderr text when err is an *exec.ExitError, so the message
// alone — even without inspecting Result.Data separately — tells the
// caller what actually went wrong, not just that it did.
func wrapExitError(name string, args []string, err error, stderr string) error {
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("running %s: %w", name, err)
	}
	cmdLine := name
	if len(args) > 0 {
		cmdLine = name + " " + strings.Join(args, " ")
	}
	if stderr == "" {
		return fmt.Errorf("%s: %w", cmdLine, err)
	}
	return fmt.Errorf("%s: %w: %s", cmdLine, err, stderr)
}
