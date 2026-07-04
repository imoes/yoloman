package modules

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Expect runs a command and answers interactive prompts it produces on
// stdout/stderr, mirroring ansible.builtin.expect. Each entry in
// `responses` maps a regular expression to the line that should be sent to
// the command's stdin the first time that expression matches the output
// seen so far; each response fires at most once.
//
// Important limitation (documented deliberately, the same way wait_for's
// hard timeout cap and uri's always-on write-gate are called out): this
// implementation pipes stdout/stderr, it does not allocate a real
// pseudo-terminal. Programs that specifically require tty semantics
// (suppressing password echo, querying terminal size, switching to raw
// mode) may behave differently than they would under a real terminal or
// under Ansible's own pexpect-based implementation, which does allocate a
// pty. For straightforward line-buffered prompts (the common case this
// module targets) piped I/O is sufficient.
type Expect struct{}

// NewExpect returns an Expect module.
func NewExpect() *Expect { return &Expect{} }

func (e *Expect) Name() string { return "expect" }

func (e *Expect) Description() string {
	return "" +
		"Run a command and answer interactive prompts it produces, via `responses` — a map from " +
		"regular expression to the line sent to the command's stdin the first time that " +
		"expression matches the accumulated output; each response fires at most once. Returns " +
		"rc/output like command; **a non-zero rc is not raised as a tool error**. Execution is " +
		"bounded by `timeout` seconds (default 30, hard-capped at 600 regardless of the " +
		"requested value, the same cap wait_for enforces). **Limitation, stated plainly**: this " +
		"pipes stdout/stderr rather than allocating a real pseudo-terminal, unlike Ansible's own " +
		"pexpect-based implementation — programs that specifically need tty semantics (echo " +
		"suppression for password prompts, terminal-size queries, raw mode) may not behave " +
		"correctly here. Suited to straightforward line-buffered prompts, not full terminal " +
		"emulation. Supports check_mode via dry_run=true (does not execute at all).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.expect. Same cmd/responses/timeout parameter names (a focused " +
		"subset — Ansible also supports a list of sequential answers per prompt and " +
		"echo/creates/removes options, not implemented here).\n" +
		"- Chef/Puppet: no dedicated resource; typically scripted with `execute`/`exec` plus a " +
		"tool like `expect(1)` itself.\n" +
		"- Salt: no dedicated state; typically wrapped via `cmd.run` plus `expect(1)`.\n" +
		"- Terraform: not applicable — see the command module's description for the general " +
		"reasoning."
}

func (e *Expect) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"cmd": stringProp(`Command line to run, split on whitespace (no quoting support), e.g. "passwd deploy".`),
		"responses": map[string]any{
			"type":                 "object",
			"additionalProperties": map[string]any{"type": "string"},
			"description":          `Map from regular expression to the line sent to stdin the first time it matches, e.g. {"[Pp]assword:": "hunter2"}.`,
		},
		"chdir":   stringProp("Optional working directory to run the command in."),
		"timeout": stringProp(`Maximum seconds to let the command run before it is killed. Default "30", hard-capped at 600.`),
		"dry_run": boolProp("When true, do not execute the command at all; report changed=true as a prediction only (check_mode).", false),
	}, "cmd", "responses")
}

func (e *Expect) Writes() bool { return true }

func (e *Expect) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	cmdLine, err := stringParam(params, "cmd", true, "")
	if err != nil {
		return Result{}, err
	}
	responses, err := stringMapParam(params, "responses")
	if err != nil {
		return Result{}, err
	}
	if len(responses) == 0 {
		return Result{}, fmt.Errorf("responses: must have at least one entry")
	}
	chdir, err := stringParam(params, "chdir", false, "")
	if err != nil {
		return Result{}, err
	}
	timeoutSecs, err := intParam(params, "timeout", 30)
	if err != nil {
		return Result{}, err
	}
	if timeoutSecs <= 0 {
		return Result{}, fmt.Errorf("timeout: must be positive")
	}
	if timeoutSecs > 600 {
		timeoutSecs = 600
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	argv := strings.Fields(cmdLine)
	if len(argv) == 0 {
		return Result{}, fmt.Errorf("cmd: must not be empty")
	}

	patterns, err := compileExpectPatterns(responses)
	if err != nil {
		return Result{}, err
	}

	if dryRun {
		return Result{Changed: true, Msg: "skipped (dry run)", Data: map[string]any{"cmd": cmdLine}}, nil
	}

	runCtx, cancel := context.WithTimeout(ctx, time.Duration(timeoutSecs)*time.Second)
	defer cancel()

	output, exitCode, sent, err := runExpect(runCtx, argv, chdir, patterns)
	if err != nil {
		return Result{}, fmt.Errorf("expect: %w", err)
	}

	return Result{Changed: true, Msg: "executed", Data: map[string]any{
		"cmd":            cmdLine,
		"rc":             exitCode,
		"output":         output,
		"responses_sent": sent,
	}}, nil
}

// expectPattern is a single compiled responses entry.
type expectPattern struct {
	key    string
	re     *regexp.Regexp
	answer string
}

// compileExpectPatterns compiles responses' regular expressions, sorted by
// key for deterministic iteration order.
func compileExpectPatterns(responses map[string]string) ([]expectPattern, error) {
	keys := make([]string, 0, len(responses))
	for k := range responses {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	patterns := make([]expectPattern, 0, len(keys))
	for _, k := range keys {
		re, err := regexp.Compile(k)
		if err != nil {
			return nil, fmt.Errorf("responses: invalid pattern %q: %w", k, err)
		}
		patterns = append(patterns, expectPattern{key: k, re: re, answer: responses[k]})
	}
	return patterns, nil
}

// firstUnansweredMatch returns the index of the first pattern (in order)
// that matches output and hasn't already been answered, or ok=false if
// none does. Factored out from runExpect so the matching logic itself can
// be unit-tested without spawning a real process.
func firstUnansweredMatch(output string, patterns []expectPattern, answered []bool) (int, bool) {
	for i, p := range patterns {
		if answered[i] {
			continue
		}
		if p.re.MatchString(output) {
			return i, true
		}
	}
	return 0, false
}

// syncBuffer is a concurrency-safe byte buffer: the spawned process writes
// to it from its own goroutine (via cmd.Stdout/Stderr) while the polling
// loop below reads a snapshot of it from another.
type syncBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

// runExpect spawns argv, and while it runs, polls its combined
// stdout+stderr output for the first unanswered pattern match, writing
// that pattern's answer (plus a newline) to stdin as soon as it's seen.
func runExpect(ctx context.Context, argv []string, chdir string, patterns []expectPattern) (output string, exitCode int, sent int, err error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = chdir

	var buf syncBuffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", 0, 0, fmt.Errorf("creating stdin pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", 0, 0, fmt.Errorf("starting command: %w", err)
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	answered := make([]bool, len(patterns))
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()

	var waitErr error
loop:
	for {
		select {
		case waitErr = <-done:
			break loop
		case <-ticker.C:
			current := buf.String()
			if idx, ok := firstUnansweredMatch(current, patterns, answered); ok {
				answered[idx] = true
				sent++
				_, _ = stdin.Write([]byte(patterns[idx].answer + "\n"))
			}
		}
	}
	_ = stdin.Close()

	if waitErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(waitErr, &exitErr) {
			return buf.String(), 0, sent, fmt.Errorf("running command: %w", waitErr)
		}
		return buf.String(), exitErr.ExitCode(), sent, nil
	}
	return buf.String(), 0, sent, nil
}
