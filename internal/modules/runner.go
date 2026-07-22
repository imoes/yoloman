package modules

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
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
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = headlessEnv()
	out, err := cmd.Output()
	if err != nil {
		return out, wrapExitError(name, args, err)
	}
	return out, nil
}

// CommandRunnerWithStdin is CommandRunner's counterpart for the handful of
// tools (dpkg --set-selections, and no others so far in this codebase) that
// only accept input via stdin, with no file-argument alternative.
type CommandRunnerWithStdin func(ctx context.Context, stdin string, name string, args ...string) ([]byte, error)

// defaultCommandRunnerWithStdin runs the real command via os/exec, feeding
// stdin to it and applying the same stderr-enriched error handling as
// defaultCommandRunner.
func defaultCommandRunnerWithStdin(ctx context.Context, stdin string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = headlessEnv()
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	if err != nil {
		return out, wrapExitError(name, args, err)
	}
	return out, nil
}

// wrapExitError enriches err (as returned by cmd.Output()/cmd.Run()) with
// the command's stderr text when err is an *exec.ExitError, so the message
// alone — even without inspecting Result.Data separately — tells the
// caller what actually went wrong, not just that it did.
func wrapExitError(name string, args []string, err error) error {
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("running %s: %w", name, err)
	}
	stderr := strings.TrimSpace(string(exitErr.Stderr))
	cmdLine := name
	if len(args) > 0 {
		cmdLine = name + " " + strings.Join(args, " ")
	}
	if stderr == "" {
		return fmt.Errorf("%s: %w", cmdLine, err)
	}
	return fmt.Errorf("%s: %w: %s", cmdLine, err, stderr)
}
