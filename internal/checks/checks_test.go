package checks

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestStatusFromExitCode(t *testing.T) {
	cases := map[int]Status{
		0: StatusOK, 1: StatusWarning, 2: StatusCritical, 3: StatusUnknown, 99: StatusUnknown,
	}
	for code, want := range cases {
		if got := StatusFromExitCode(code); got != want {
			t.Errorf("StatusFromExitCode(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestParseOutput_SimpleOKWithPerfdata(t *testing.T) {
	res := ParseOutput(0, "DISK OK - 45% used | used=45%;80;90;0;100\n")
	if res.Status != StatusOK {
		t.Errorf("status = %q, want OK", res.Status)
	}
	if res.Message != "DISK OK - 45% used" {
		t.Errorf("message = %q", res.Message)
	}
	if len(res.Perfdata) != 1 {
		t.Fatalf("expected 1 perfdata point, got %d: %+v", len(res.Perfdata), res.Perfdata)
	}
	pd := res.Perfdata[0]
	if pd.Label != "used" || pd.Value != "45%" || pd.Warn != "80" || pd.Crit != "90" || pd.Min != "0" || pd.Max != "100" {
		t.Errorf("unexpected perfdata: %+v", pd)
	}
}

func TestParseOutput_MultiplePerfdataPoints(t *testing.T) {
	res := ParseOutput(0, "OK - all good | cpu=10% mem=55%;80;95\n")
	if len(res.Perfdata) != 2 {
		t.Fatalf("expected 2 perfdata points, got %+v", res.Perfdata)
	}
	if res.Perfdata[0].Label != "cpu" || res.Perfdata[0].Value != "10%" {
		t.Errorf("unexpected first perfdata: %+v", res.Perfdata[0])
	}
	if res.Perfdata[1].Label != "mem" || res.Perfdata[1].Warn != "80" {
		t.Errorf("unexpected second perfdata: %+v", res.Perfdata[1])
	}
}

func TestParseOutput_NoPerfdata(t *testing.T) {
	res := ParseOutput(2, "CRITICAL - disk full\n")
	if res.Status != StatusCritical {
		t.Errorf("status = %q, want CRITICAL", res.Status)
	}
	if res.Message != "CRITICAL - disk full" {
		t.Errorf("message = %q", res.Message)
	}
	if len(res.Perfdata) != 0 {
		t.Errorf("expected no perfdata, got %+v", res.Perfdata)
	}
}

func TestParseOutput_LongOutput(t *testing.T) {
	res := ParseOutput(1, "WARNING - something\nadditional detail line 1\nadditional detail line 2\n")
	if res.Message != "WARNING - something" {
		t.Errorf("message = %q", res.Message)
	}
	if res.LongOutput != "additional detail line 1\nadditional detail line 2" {
		t.Errorf("long_output = %q", res.LongOutput)
	}
}

func TestParseOutput_EmptyOutput(t *testing.T) {
	res := ParseOutput(3, "")
	if res.Status != StatusUnknown {
		t.Errorf("status = %q, want UNKNOWN", res.Status)
	}
	if res.Message != "" {
		t.Errorf("message = %q, want empty", res.Message)
	}
}

func TestRun_UsesExecFuncAndParses(t *testing.T) {
	var gotArgv []string
	fakeExec := func(ctx context.Context, argv []string, timeout time.Duration) (string, int, error) {
		gotArgv = argv
		return "OK - fake check | value=1\n", 0, nil
	}

	res, err := Run(context.Background(), fakeExec, []string{"check_fake", "-w", "1"}, 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Status != StatusOK || res.Message != "OK - fake check" {
		t.Errorf("unexpected result: %+v", res)
	}
	if len(gotArgv) != 3 || gotArgv[0] != "check_fake" {
		t.Errorf("unexpected argv passed to exec: %v", gotArgv)
	}
}

func TestRun_ExecStartFailurePropagates(t *testing.T) {
	fakeExec := func(ctx context.Context, argv []string, timeout time.Duration) (string, int, error) {
		return "", 0, errors.New("exec: not found")
	}
	if _, err := Run(context.Background(), fakeExec, []string{"nosuchplugin"}, 0); err == nil {
		t.Fatal("expected error when the process fails to start")
	}
}

func TestDefaultExec_RealCriticalExit(t *testing.T) {
	// /bin/sh is always present on Linux; emulate a plugin returning
	// CRITICAL (exit 2) with a perfdata line.
	output, exitCode, err := DefaultExec(context.Background(), []string{
		"/bin/sh", "-c", "echo 'CRITICAL - disk full | used=99%;80;90'; exit 2",
	}, 0)
	if err != nil {
		t.Fatalf("DefaultExec: %v", err)
	}
	if exitCode != 2 {
		t.Errorf("exitCode = %d, want 2", exitCode)
	}
	res := ParseOutput(exitCode, output)
	if res.Status != StatusCritical {
		t.Errorf("status = %q, want CRITICAL", res.Status)
	}
	if len(res.Perfdata) != 1 || res.Perfdata[0].Label != "used" {
		t.Errorf("unexpected perfdata: %+v", res.Perfdata)
	}
}

func TestDefaultExec_StartFailure(t *testing.T) {
	if _, _, err := DefaultExec(context.Background(), []string{"/no/such/binary-xyz"}, 0); err == nil {
		t.Fatal("expected error for a nonexistent binary")
	}
}

func TestRunDefault_RealOKCheck(t *testing.T) {
	res, err := RunDefault(context.Background(), []string{"/bin/sh", "-c", "echo 'OK - all good'; exit 0"}, 0)
	if err != nil {
		t.Fatalf("RunDefault: %v", err)
	}
	if res.Status != StatusOK || res.Message != "OK - all good" {
		t.Errorf("unexpected result: %+v", res)
	}
}
