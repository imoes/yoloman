package modules

import (
	"context"
	"os/exec"
)

// CommandRunner executes name with args and returns its stdout. It exists so
// modules that must shell out (service_facts, package_facts, getent — there
// is no pure-/proc source for systemd/dpkg/NSS state) can be tested with a
// canned runner instead of depending on the real host's tools.
type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

// defaultCommandRunner runs the real command via os/exec.
func defaultCommandRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	return cmd.Output()
}
