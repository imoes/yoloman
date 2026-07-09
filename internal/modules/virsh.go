package modules

import (
	"context"
	"fmt"
	"strings"
)

// Virsh manages a libvirt/KVM domain through the local `virsh` CLI, mirroring
// the qm module for libvirt hosts: a desired running state
// (started/stopped/shutdown/rebooted), idempotent for the state-comparison
// cases via `virsh domstate`. Runner is injectable for testing.
type Virsh struct {
	Runner CommandRunner
}

// NewVirsh returns a Virsh module backed by the real virsh CLI.
func NewVirsh() *Virsh { return &Virsh{Runner: defaultCommandRunner} }

func (m *Virsh) Name() string { return "virsh" }

func (m *Virsh) Description() string {
	return "" +
		"Control a libvirt/KVM domain via the local `virsh` CLI. state: started (virsh start), " +
		"stopped (virsh destroy — hard off), shutdown (virsh shutdown — graceful ACPI), rebooted " +
		"(virsh reboot). started/stopped/shutdown are idempotent: `virsh domstate <domain>` is " +
		"checked first and the domain is only touched when the running state differs; rebooted " +
		"always acts. check_mode via dry_run=true queries but issues no mutating command. " +
		"Requires the domain name.\n\n" +
		"Mirrors ansible community.libvirt.virt (state=running/shutdown/destroyed) but drives the " +
		"host directly via virsh. List domains with the read-only virt_facts module."
}

func (m *Virsh) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"domain":  stringProp("The libvirt domain (VM) name, e.g. \"web01\"."),
		"state":   stringEnumProp("Desired domain state.", "started", "stopped", "shutdown", "rebooted"),
		"dry_run": boolProp("When true, report what would change without issuing any mutating virsh command (check_mode).", false),
	}, "domain", "state")
}

func (m *Virsh) Writes() bool { return true }

func (m *Virsh) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	domain, err := stringParam(params, "domain", true, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", true, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	data := map[string]any{"domain": domain}
	changed := false

	switch state {
	case "started", "stopped", "shutdown":
		running, err := m.isRunning(ctx, domain)
		if err != nil {
			return Result{}, err
		}
		data["was_running"] = running
		wantRunning := state == "started"
		if running != wantRunning {
			changed = true
			if !dryRun {
				action := map[string]string{"started": "start", "stopped": "destroy", "shutdown": "shutdown"}[state]
				if _, err := m.Runner(ctx, "virsh", action, domain); err != nil {
					return Result{}, fmt.Errorf("virsh: %s %s: %w", action, domain, err)
				}
			}
		}
	case "rebooted":
		changed = true
		if !dryRun {
			if _, err := m.Runner(ctx, "virsh", "reboot", domain); err != nil {
				return Result{}, fmt.Errorf("virsh: reboot %s: %w", domain, err)
			}
		}
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want started|stopped|shutdown|rebooted)", state)
	}

	return Result{Changed: changed, Msg: "state applied", Data: data}, nil
}

// isRunning reports whether `virsh domstate <domain>` says "running".
func (m *Virsh) isRunning(ctx context.Context, domain string) (bool, error) {
	out, err := m.Runner(ctx, "virsh", "domstate", domain)
	if err != nil {
		return false, fmt.Errorf("virsh: querying domstate for %s: %w", domain, err)
	}
	return strings.TrimSpace(string(out)) == "running", nil
}
