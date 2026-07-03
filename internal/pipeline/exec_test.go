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
