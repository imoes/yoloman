package modules

import (
	"context"
	"strings"
	"testing"
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
