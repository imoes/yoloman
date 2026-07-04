package modules

import (
	"context"
	"fmt"
	"os"
)

// HostnameFunc returns the current kernel hostname. Injectable for testing
// (real implementation: os.Hostname).
type HostnameFunc func() (string, error)

// Hostname ensures the system hostname matches a desired value, mirroring
// ansible.builtin.hostname. It targets systemd-based Linux, like the rest
// of this agent's write modules (see systemd.go) — hostnamectl is the one
// tool that reliably updates both the transient (kernel) and static
// (/etc/hostname) hostname together.
type Hostname struct {
	Runner      CommandRunner
	CurrentHost HostnameFunc
}

// NewHostname returns a Hostname module backed by the real hostnamectl
// binary and os.Hostname.
func NewHostname() *Hostname {
	return &Hostname{Runner: defaultCommandRunner, CurrentHost: os.Hostname}
}

func (h *Hostname) Name() string { return "hostname" }

func (h *Hostname) Description() string {
	return "" +
		"Ensure the system's hostname matches a desired value, using hostnamectl (systemd-based " +
		"Linux, like the rest of this agent). Idempotent — compares the current kernel hostname " +
		"first and only calls hostnamectl when it differs. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.hostname. Same name parameter; Ansible supports multiple " +
		"per-distro strategies (systemd/redhat/debian/...), this module only implements the " +
		"systemd (hostnamectl) strategy.\n" +
		"- Chef: no single built-in resource; typically a `execute` resource wrapping " +
		"hostnamectl, or the community 'hostname' cookbook.\n" +
		"- Puppet: no core equivalent; augeasproviders or an `exec` wrapping hostnamectl.\n" +
		"- Salt: the `network.system` state's `hostname` parameter, or the `system.set_computer_" +
		"desc`-style execution modules.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's kernel state."
}

func (h *Hostname) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Desired hostname, e.g. "web01.example.com".`),
		"dry_run": boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (h *Hostname) Writes() bool { return true }

func (h *Hostname) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	current, err := h.CurrentHost()
	if err != nil {
		return Result{}, fmt.Errorf("hostname: reading current hostname: %w", err)
	}

	if current == name {
		return Result{Changed: false, Msg: "hostname already set", Data: map[string]any{"name": name}}, nil
	}

	if !dryRun {
		if _, err := h.Runner(ctx, "hostnamectl", "set-hostname", name); err != nil {
			return Result{}, fmt.Errorf("hostname: setting %q: %w", name, err)
		}
	}
	return Result{Changed: true, Msg: "hostname updated", Data: map[string]any{"name": name, "previous": current}}, nil
}
