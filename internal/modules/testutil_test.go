package modules

import (
	"os/exec"
	"strconv"
)

// exitStatus runs a trivial real subprocess that exits with code, returning
// a genuine *exec.ExitError with that exit code — the simplest way to
// construct one for tests that need to distinguish one exit status from
// another (e.g. getent's "not found" is specifically exit code 2, not just
// "any error").
func exitStatus(code int) *exec.ExitError {
	cmd := exec.Command("sh", "-c", "exit "+strconv.Itoa(code))
	err := cmd.Run()
	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		panic("exitStatus: expected *exec.ExitError")
	}
	return exitErr
}
