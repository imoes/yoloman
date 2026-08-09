package pipeline

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// DefaultTimeout bounds how long a pipeline may run before being killed.
const DefaultTimeout = 30 * time.Second

// DefaultMaxOutput caps how many bytes of the final stage's stdout are
// returned, guarding against pathological or runaway output.
const DefaultMaxOutput = 1 << 20 // 1 MiB

// StageResult captures one pipeline stage's own exit code and stderr. A
// stage earlier than the last can fail (or print a diagnostic to stderr)
// while the overall pipeline still "succeeds" in the sense that the final
// stage ran to completion (e.g. `false | wc -l` still produces output) —
// without per-stage detail, that failure would be invisible to a caller
// (or an AI) trying to understand why a pipeline didn't do what was
// expected.
type StageResult struct {
	Cmd      string `json:"cmd"`
	ExitCode int    `json:"exit_code"`
	Stderr   string `json:"stderr,omitempty"`
}

// Result is the outcome of running a pipeline: the last stage's stdout
// (capped at maxOutput), Stdout/Stderr/ExitCode mirror the last stage for
// backward-compatible convenience access, and Stages carries every stage's
// own exit code and stderr for full visibility into what actually happened.
type Result struct {
	Stdout   string        `json:"stdout"`
	Stderr   string        `json:"stderr"`
	ExitCode int           `json:"exit_code"`
	Stages   []StageResult `json:"stages"`
}

// Run validates every stage against policy, then executes the stages
// chained together (stage i's stdout feeds stage i+1's stdin) with no
// shell involved — no redirects, substitution, or globbing beyond what each
// binary does on its own. Only the final stage's stdout is returned; a
// non-zero final exit code is ordinary data, not a Go error.
func Run(ctx context.Context, policy *Policy, stages [][]string, timeout time.Duration, maxOutput int64) (Result, error) {
	if len(stages) == 0 {
		return Result{}, fmt.Errorf("pipeline: no stages given")
	}
	for i, stage := range stages {
		if err := policy.Validate(stage); err != nil {
			return Result{}, fmt.Errorf("pipeline stage %d: %w", i, err)
		}
	}
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	if maxOutput <= 0 {
		maxOutput = DefaultMaxOutput
	}

	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmds := make([]*exec.Cmd, len(stages))
	for i, stage := range stages {
		cmds[i] = exec.CommandContext(ctx, stage[0], stage[1:]...)
	}
	for i := 0; i < len(cmds)-1; i++ {
		pipe, err := cmds[i].StdoutPipe()
		if err != nil {
			return Result{}, fmt.Errorf("pipeline: wiring stage %d -> %d: %w", i, i+1, err)
		}
		cmds[i+1].Stdin = pipe
	}

	var finalOut bytes.Buffer
	cmds[len(cmds)-1].Stdout = &finalOut
	stderrs := make([]bytes.Buffer, len(cmds))
	for i := range cmds {
		cmds[i].Stderr = &stderrs[i]
	}

	for i, c := range cmds {
		if err := c.Start(); err != nil {
			return Result{}, fmt.Errorf("pipeline: starting stage %d (%s): %w", i, stages[i][0], err)
		}
	}

	exitCode := 0
	stageResults := make([]StageResult, len(cmds))
	for i, c := range cmds {
		sr := StageResult{Cmd: strings.Join(stages[i], " ")}
		if err := c.Wait(); err != nil {
			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) {
				return Result{}, fmt.Errorf("pipeline: running stage %d (%s): %w", i, stages[i][0], err)
			}
			sr.ExitCode = exitErr.ExitCode()
			if i == len(cmds)-1 {
				exitCode = sr.ExitCode
			}
		}
		sr.Stderr = strings.TrimSpace(stderrs[i].String())
		stageResults[i] = sr
	}

	out := finalOut.Bytes()
	if int64(len(out)) > maxOutput {
		out = out[:maxOutput]
	}
	return Result{
		Stdout:   string(out),
		Stderr:   stageResults[len(stageResults)-1].Stderr,
		ExitCode: exitCode,
		Stages:   stageResults,
	}, nil
}
