package starmodules

import "testing"

// A read-only run of a tool that isn't installed must read as "no data" (rc 127),
// not kill the module: Starlark has no exceptions, so the hard error took the
// whole check down — which is how a Linux host ended up with no NIC check at all
// (lnx_if calls ethtool). Checkmk's agent guards the same case with `if inpath`.
func TestRunMissingBinaryIsDataWhenReadOnly(t *testing.T) {
	caps := NewRealCaps(false, false, false)
	rr, err := caps.Run([]string{"definitely-not-a-real-binary-xyz", "--help"}, false, nil)
	if err != nil {
		t.Fatalf("read-only run of a missing binary must not error: %v", err)
	}
	if rr.RC != 127 {
		t.Errorf("rc = %d, want 127 (shell's convention for command not found)", rr.RC)
	}
	if rr.Stdout != "" {
		t.Errorf("stdout = %q, want empty", rr.Stdout)
	}
}

// Failing to DO something stays loud. A runbook that cannot find its package
// manager must not report success.
func TestRunMissingBinaryStillFailsWhenMutating(t *testing.T) {
	caps := NewRealCaps(false, true, true) // write gate open, module writes
	if _, err := caps.Run([]string{"definitely-not-a-real-binary-xyz"}, true, nil); err == nil {
		t.Fatal("a mutating run of a missing binary must return an error")
	}
}
