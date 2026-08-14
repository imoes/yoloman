package modules

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// CommandExecFunc runs argv (no shell involved) with an optional working
// directory and returns its captured stdout/stderr and exit code. A non-zero
// exit code is ordinary data, not a Go error — only a failure to start the
// process at all (e.g. the binary doesn't exist) is returned as err.
// CommandExecFunc runs argv (no shell involved) with an optional working
// directory and extra environment, and returns its captured stdout/stderr and
// exit code. A non-zero exit code is ordinary data, not a Go error — only a
// failure to start the process at all (e.g. the binary doesn't exist) is
// returned as err.
type CommandExecFunc func(ctx context.Context, argv []string, chdir string, env map[string]string) (stdout, stderr []byte, exitCode int, err error)

// defaultCommandExec runs argv via os/exec.
//
// `env` is ADDED to the inherited environment rather than replacing it: a script
// that suddenly loses PATH, HOME or the proxy variables would fail for reasons
// nothing in the call describes.
func defaultCommandExec(ctx context.Context, argv []string, chdir string, env map[string]string) (stdout, stderr []byte, exitCode int, err error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = chdir
	if len(env) > 0 {
		cmd.Env = os.Environ()
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
	}
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	runErr := cmd.Run()
	if runErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(runErr, &exitErr) {
			return nil, nil, 0, fmt.Errorf("starting command: %w", runErr)
		}
		return outBuf.Bytes(), errBuf.Bytes(), exitErr.ExitCode(), nil
	}
	return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}

// Command runs an arbitrary command with no shell interpretation, mirroring
// ansible.builtin.command. Unlike the read/facts modules, it cannot know in
// advance whether running it will change anything, so — like Ansible — it
// always reports changed=true when it actually runs. In check_mode
// (dry_run=true) it does not execute at all, matching Ansible's default
// behavior of skipping command/shell tasks under --check.
type Command struct {
	Exec CommandExecFunc
}

// NewCommand returns a Command module backed by the real os/exec.
func NewCommand() *Command { return &Command{Exec: defaultCommandExec} }

func (c *Command) Name() string { return "command" }

func (c *Command) Description() string {
	return "" +
		"Run an arbitrary command with no shell involved — no pipes, redirects, globbing, or " +
		"variable substitution, exactly like ansible.builtin.command (use the agent's separate " +
		"pipeline tool, not this one, when you actually need `cmd1 | cmd2`). Provide either " +
		"`cmd` (a plain command line, split on whitespace — no quoting support) or the explicit " +
		"`argv` array (preferred whenever an argument contains spaces or special characters). " +
		"Returns rc/stdout/stderr; **a non-zero rc is not raised as a tool error** — check " +
		"data.rc yourself to determine success. This module cannot verify idempotency for an " +
		"arbitrary command, so it always reports changed=true once it actually runs; under " +
		"check_mode (dry_run=true) it does not run at all and reports changed=true as a " +
		"prediction only, matching Ansible's default of skipping command/shell tasks during " +
		"--check.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.command (and, for genuinely shell-requiring cases, " +
		"ansible.builtin.shell — not implemented here; use the pipeline tool instead).\n" +
		"- Chef: the `execute` resource.\n" +
		"- Puppet: the `exec` type.\n" +
		"- Salt: the `cmd.run` execution module / `cmd.run` state.\n" +
		"- Terraform: a `null_resource` with a `local-exec`/`remote-exec` provisioner."
}

func (c *Command) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"cmd":     stringProp(`Plain command line, split on whitespace (no quoting), e.g. "systemctl daemon-reload". Mutually exclusive with argv.`),
		"argv":    stringArrayProp(`Explicit argument vector, e.g. ["mkdir", "-p", "/opt/my app"] — required whenever an argument contains spaces. Mutually exclusive with cmd.`),
		"chdir":   stringProp("Optional working directory to run the command in."),
		"env": objectMapProp("Extra environment variables for this one call, ADDED to the " +
			"inherited environment (PATH/HOME stay intact). Values are passed through the process " +
			"environment, not the command line, so they do not appear in `ps` output or a shell " +
			"history — which is why an event handler's parameters travel this way."),
		"dry_run": boolProp("When true, do not execute the command at all; report changed=true as a prediction only (check_mode).", false),
	})
}

func (c *Command) Writes() bool { return true }

func (c *Command) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	cmdLine, err := stringParam(params, "cmd", false, "")
	if err != nil {
		return Result{}, err
	}
	argv, err := stringSliceParam(params, "argv", false)
	if err != nil {
		return Result{}, err
	}
	chdir, err := stringParam(params, "chdir", false, "")
	if err != nil {
		return Result{}, err
	}
	env, err := stringMapParam(params, "env")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	_, hasCmd := params["cmd"]
	_, hasArgv := params["argv"]
	if hasCmd == hasArgv {
		return Result{}, fmt.Errorf("command: exactly one of cmd or argv must be given")
	}
	if hasCmd {
		argv = strings.Fields(cmdLine)
		if len(argv) == 0 {
			return Result{}, fmt.Errorf("command: cmd must not be empty")
		}
	}

	if dryRun {
		return Result{Changed: true, Msg: "skipped (dry run)", Data: map[string]any{
			"cmd": strings.Join(argv, " "),
		}}, nil
	}

	stdout, stderr, exitCode, err := c.Exec(ctx, argv, chdir, env)
	if err != nil {
		return Result{}, fmt.Errorf("command: %w", err)
	}

	return Result{Changed: true, Msg: "executed", Data: map[string]any{
		"cmd":    strings.Join(argv, " "),
		"rc":     exitCode,
		"stdout": string(stdout),
		"stderr": string(stderr),
	}}, nil
}
