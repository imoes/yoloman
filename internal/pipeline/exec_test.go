package pipeline

import (
	"context"
	"strings"
	"testing"
	"time"
)

func permissivePolicy(binaries ...string) *Policy {
	p := &Policy{}
	for _, b := range binaries {
		p.Allow = append(p.Allow, AllowedCommand{Binary: b})
	}
	return p
}

func TestRun_TwoStagePipe(t *testing.T) {
	stages := [][]string{
		{"printf", "hello\nworld\n"},
		{"grep", "world"},
	}
	res, err := Run(context.Background(), permissivePolicy("printf", "grep"), stages, 0, 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(res.Stdout) != "world" {
		t.Errorf("stdout = %q, want %q", res.Stdout, "world")
	}
	if res.ExitCode != 0 {
		t.Errorf("exit code = %d, want 0", res.ExitCode)
	}
}

func TestRun_ThreeStagePipe(t *testing.T) {
	stages := [][]string{
		{"printf", "a\nb\nc\n"},
		{"tr", "a-z", "A-Z"},
		{"grep", "B"},
	}
	res, err := Run(context.Background(), permissivePolicy("printf", "tr", "grep"), stages, 0, 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(res.Stdout) != "B" {
		t.Errorf("stdout = %q, want %q", res.Stdout, "B")
	}
}

func TestRun_PolicyRejectsDisallowedStage(t *testing.T) {
	stages := [][]string{
		{"printf", "x"},
		{"rm", "-rf", "/"},
	}
	if _, err := Run(context.Background(), permissivePolicy("printf"), stages, 0, 0); err == nil {
		t.Fatal("expected error for disallowed stage")
	}
}

func TestRun_NonZeroFinalExitIsNotAnError(t *testing.T) {
	stages := [][]string{
		{"printf", "hello\n"},
		{"grep", "nomatch"},
	}
	res, err := Run(context.Background(), permissivePolicy("printf", "grep"), stages, 0, 0)
	if err != nil {
		t.Fatalf("expected no Go error for grep finding nothing, got %v", err)
	}
	if res.ExitCode == 0 {
		t.Error("expected non-zero exit code when grep finds nothing")
	}
}

func TestRun_NoStages(t *testing.T) {
	if _, err := Run(context.Background(), EmptyPolicy(), nil, 0, 0); err == nil {
		t.Fatal("expected error for no stages")
	}
}

func TestRun_MaxOutputTruncates(t *testing.T) {
	stages := [][]string{{"printf", "0123456789"}}
	res, err := Run(context.Background(), permissivePolicy("printf"), stages, 0, 4)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Stdout != "0123" {
		t.Errorf("stdout = %q, want truncated %q", res.Stdout, "0123")
	}
}

func TestRun_TimeoutKillsHangingCommand(t *testing.T) {
	stages := [][]string{{"sleep", "5"}}
	start := time.Now()
	_, err := Run(context.Background(), permissivePolicy("sleep"), stages, 100*time.Millisecond, 0)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if elapsed > 2*time.Second {
		t.Errorf("expected timeout to kill sleep quickly, took %v", elapsed)
	}
}

func TestRun_SingleStage(t *testing.T) {
	res, err := Run(context.Background(), permissivePolicy("printf"), [][]string{{"printf", "solo"}}, 0, 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Stdout != "solo" {
		t.Errorf("stdout = %q, want %q", res.Stdout, "solo")
	}
}

// TestRun_EarlierStageFailureVisibleInStages guards against losing an
// earlier stage's failure: `ls <missing> | cat` fails at stage 0 (real
// stderr output, non-zero exit) but stage 1 (cat) still runs to completion
// on empty input and exits 0 — the overall pipeline "succeeds" by the old
// last-stage-only definition, silently hiding why stage 0 didn't do what
// was expected. Stages must expose stage 0's real exit code and stderr.
func TestRun_EarlierStageFailureVisibleInStages(t *testing.T) {
	stages := [][]string{
		{"ls", "/no-such-path-xyz-123"},
		{"cat"},
	}
	res, err := Run(context.Background(), permissivePolicy("ls", "cat"), stages, 0, 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ExitCode != 0 {
		t.Errorf("overall ExitCode = %d, want 0 (last stage succeeded)", res.ExitCode)
	}
	if len(res.Stages) != 2 {
		t.Fatalf("expected 2 per-stage results, got %d", len(res.Stages))
	}
	if res.Stages[0].ExitCode == 0 {
		t.Error("expected stage 0 (ls on a missing path) to report a non-zero exit code")
	}
	if res.Stages[0].Stderr == "" {
		t.Error("expected stage 0's stderr to be captured, not lost")
	}
	if res.Stages[1].ExitCode != 0 {
		t.Errorf("expected stage 1 (cat) to succeed, got exit code %d", res.Stages[1].ExitCode)
	}
}
