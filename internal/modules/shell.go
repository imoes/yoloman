package modules

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
)

// ShellExecFunc runs script through a shell interpreter and returns its
// captured stdout/stderr and exit code. A non-zero exit code is ordinary
// data, not a Go error — only a failure to start the shell at all is
// returned as err.
type ShellExecFunc func(ctx context.Context, script, executable, chdir string) (stdout, stderr []byte, exitCode int, err error)

// defaultShellExec runs script via `<executable> -c <script>`.
func defaultShellExec(ctx context.Context, script, executable, chdir string) (stdout, stderr []byte, exitCode int, err error) {
	cmd := exec.CommandContext(ctx, executable, "-c", script)
	cmd.Dir = chdir
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	runErr := cmd.Run()
	if runErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(runErr, &exitErr) {
			return nil, nil, 0, fmt.Errorf("starting shell: %w", runErr)
		}
		return outBuf.Bytes(), errBuf.Bytes(), exitErr.ExitCode(), nil
	}
	return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}

// Shell runs a command line through a real shell interpreter, mirroring
// ansible.builtin.shell.
//
// **Deliberate, explicit exception to this project's security model.**
// docs/plan.md states this project's security model as "no shell
// interpreter" — exec.Command with argv only, no redirects/substitution —
// specifically to make shell injection structurally impossible for every
// other tool in this agent. This module is the one, intentional exception:
// real ansible.builtin.shell exists precisely to run shell syntax (pipes,
// redirects, globbing, `$()` substitution, env var expansion), which is
// not expressible as an argv array. Confirmed with the project owner as an
// accepted trade-off rather than an oversight: unlike every other tool
// here, the caller (an AI client or human operator) is responsible for not
// passing untrusted/attacker-influenced content into `cmd` — this agent
// does not, and structurally cannot, sanitize shell syntax on this one
// tool's behalf. If you need argv-only execution with the injection-safety
// guarantee the rest of this module set provides, use `command` (or
// `raw`, its alias) instead.
type Shell struct {
	Exec ShellExecFunc
}

// NewShell returns a Shell module backed by the real /bin/sh.
func NewShell() *Shell { return &Shell{Exec: defaultShellExec} }

func (s *Shell) Name() string { return "shell" }

func (s *Shell) Description() string {
	return "" +
		"Run a command line through a real shell interpreter (pipes, redirects, globbing, `$()` " +
		"substitution, env var expansion all work, exactly like a real shell prompt) — the ONE " +
		"deliberate exception to this agent's normal \"no shell, argv only\" execution model (see " +
		"command/raw). **Because of that, this tool has no injection protection**: whatever `cmd` " +
		"contains is interpreted by the shell verbatim. Never pass untrusted or externally-" +
		"influenced text into `cmd` — prefer `command`/`raw` (argv, no shell involved) or the " +
		"agent's separate whitelisted pipeline tool whenever shell syntax isn't actually needed. " +
		"Returns rc/stdout/stderr; **a non-zero rc is not raised as a tool error** — check " +
		"data.rc yourself. Cannot verify idempotency for an arbitrary shell command, so it always " +
		"reports changed=true once it actually runs; under check_mode (dry_run=true) it does not " +
		"run at all and reports changed=true as a prediction only, matching Ansible's default of " +
		"skipping command/shell tasks during --check.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.shell. Same cmd/executable/chdir parameter names.\n" +
		"- Chef: the `bash`/`execute` resources with `user`-supplied shell syntax.\n" +
		"- Puppet: the `exec` type with `provider => shell`.\n" +
		"- Salt: the `cmd.run` execution module / state (shell=True equivalent).\n" +
		"- Terraform: a `null_resource` with a `local-exec`/`remote-exec` provisioner."
}

func (s *Shell) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"cmd":        stringProp(`Full shell command line, interpreted verbatim by executable, e.g. "ps aux | grep nginx | wc -l".`),
		"executable": stringProp(`Shell to run cmd through. Default "/bin/sh".`),
		"chdir":      stringProp("Optional working directory to run the command in."),
		"dry_run":    boolProp("When true, do not execute the command at all; report changed=true as a prediction only (check_mode).", false),
	}, "cmd")
}

func (s *Shell) Writes() bool { return true }

func (s *Shell) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	cmdLine, err := stringParam(params, "cmd", true, "")
	if err != nil {
		return Result{}, err
	}
	if cmdLine == "" {
		return Result{}, fmt.Errorf("cmd: must not be empty")
	}
	executable, err := stringParam(params, "executable", false, "/bin/sh")
	if err != nil {
		return Result{}, err
	}
	chdir, err := stringParam(params, "chdir", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if dryRun {
		return Result{Changed: true, Msg: "skipped (dry run)", Data: map[string]any{"cmd": cmdLine}}, nil
	}

	stdout, stderr, exitCode, err := s.Exec(ctx, cmdLine, executable, chdir)
	if err != nil {
		return Result{}, fmt.Errorf("shell: %w", err)
	}

	return Result{Changed: true, Msg: "executed", Data: map[string]any{
		"cmd":        cmdLine,
		"executable": executable,
		"rc":         exitCode,
		"stdout":     string(stdout),
		"stderr":     string(stderr),
	}}, nil
}
