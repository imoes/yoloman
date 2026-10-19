package modules

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestDefaultCommandRunner_FailureIncludesStderr guards the fix this test
// was written for: a failing command's error must include the command's
// actual stderr text, not just the bare exit status — an exit code alone
// doesn't tell a caller (especially an AI deciding what to do next) *why*
// something failed.
func TestDefaultCommandRunner_FailureIncludesStderr(t *testing.T) {
	_, err := defaultCommandRunner(context.Background(), "ls", "/no-such-path-xyz-123")
	if err == nil {
		t.Fatal("expected error for a nonexistent path")
	}
	msg := err.Error()
	// Don't assert on ls's exact (locale-dependent) wording — assert that
	// the real command line and its stderr text are both present, not
	// just the bare "exit status N" exec.ExitError.Error() would produce
	// on its own.
	if !strings.Contains(msg, "no-such-path-xyz-123") {
		t.Errorf("error message = %q, expected it to include the failing path", msg)
	}
	if !strings.Contains(msg, "exit status") {
		t.Errorf("error message = %q, expected it to still include the exit status", msg)
	}
	if len(msg) <= len("ls /no-such-path-xyz-123: exit status 2") {
		t.Errorf("error message = %q, expected more than just the bare exit status (no stderr captured)", msg)
	}
}

func TestDefaultCommandRunner_SuccessReturnsCleanStdout(t *testing.T) {
	out, err := defaultCommandRunner(context.Background(), "printf", "hello")
	if err != nil {
		t.Fatalf("defaultCommandRunner: %v", err)
	}
	if string(out) != "hello" {
		t.Errorf("stdout = %q, want %q", out, "hello")
	}
}

func TestDefaultCommandRunner_MissingBinaryError(t *testing.T) {
	_, err := defaultCommandRunner(context.Background(), "this-binary-does-not-exist-xyz")
	if err == nil {
		t.Fatal("expected error for a nonexistent binary")
	}
}

// A command that floods its output (a postinst re-asking a prompt on an empty stdin) is stopped at the cap and the
// error quotes what it was printing — it used to be buffered whole until the host ran out of memory.
func TestDefaultCommandRunner_RunawayOutputIsStoppedWithItsLastLines(t *testing.T) {
	old := maxCommandOutput
	maxCommandOutput = 1 << 16
	defer func() { maxCommandOutput = old }()
	_, err := defaultCommandRunner(context.Background(), "sh", "-c", "while :; do echo 'Area code []?'; done")
	if err == nil {
		t.Fatal("expected the runaway command to be stopped")
	}
	if !strings.Contains(err.Error(), "was stopped") || !strings.Contains(err.Error(), "Area code []?") {
		t.Errorf("error should say it was stopped and quote the prompt, got: %v", err)
	}
}

// The runaway child of a child (apt → postinst → faxsetup) is stopped too: killing only the direct child left the
// grandchild writing into the pipe, and Wait never returned.
func TestDefaultCommandRunner_RunawayGrandchildIsStopped(t *testing.T) {
	old := maxCommandOutput
	maxCommandOutput = 1 << 16
	defer func() { maxCommandOutput = old }()
	done := make(chan error, 1)
	go func() {
		_, err := defaultCommandRunner(context.Background(), "sh", "-c", "sh -c 'while :; do echo Area code; done' ; sleep 300")
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "was stopped") {
			t.Errorf("expected a stop error, got %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the runaway grandchild kept the runner waiting")
	}
}

// A failing command whose cause is on STDOUT (dpkg's maintainer-script errors) carries that cause in its error.
func TestRunCapped_FailureNamesTheCauseFromStdout(t *testing.T) {
	_, err := runCapped(context.Background(), nil, "sh", "-c",
		"echo 'Setting up resolvconf'; echo \"ln: failed to create symbolic link '/etc/resolv.conf': Device or resource busy\"; "+
			"echo 'dpkg: error processing package resolvconf (--configure):'; echo 'E: Sub-process returned an error code (1)' >&2; exit 100")
	if err == nil {
		t.Fatal("expected an error")
	}
	msg := err.Error()
	for _, want := range []string{"Device or resource busy", "error processing package resolvconf", "Sub-process returned"} {
		if !strings.Contains(msg, want) {
			t.Errorf("error lacks %q: %s", want, msg)
		}
	}
	if strings.Count(msg, "Setting up resolvconf") > 1 { // once in the echoed command line, never as a cause
		t.Errorf("progress lines are not causes: %s", msg)
	}
}
