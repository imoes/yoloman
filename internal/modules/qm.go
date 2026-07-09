package modules

import (
	"context"
	"fmt"
	"strings"
)

// QM manages a Proxmox VE QEMU virtual machine through the local `qm` CLI on
// the node, mirroring the systemd module's shape for VMs: a desired running
// state (started/stopped/shutdown/rebooted/reset), idempotent for the
// state-comparison cases via `qm status`. This is LOCAL node control, distinct
// from the API-based community.general.proxmox_kvm module. Runner is
// injectable for testing.
type QM struct {
	Runner CommandRunner
}

// NewQM returns a QM module backed by the real qm CLI.
func NewQM() *QM { return &QM{Runner: defaultCommandRunner} }

func (m *QM) Name() string { return "qm" }

func (m *QM) Description() string {
	return "" +
		"Control a Proxmox VE QEMU VM on this node via the local `qm` CLI. state: started (qm " +
		"start), stopped (qm stop — hard off), shutdown (qm shutdown — graceful ACPI), rebooted " +
		"(qm reboot), reset (qm reset — hard). started/stopped/shutdown are idempotent: `qm " +
		"status <vmid>` is checked first and the VM is only touched when the running state " +
		"differs; rebooted/reset always act (like a systemd restart). check_mode via dry_run=true " +
		"queries but issues no mutating qm command. Requires the vmid.\n\n" +
		"This drives the node locally (the agent runs on the Proxmox host); to manage a Proxmox " +
		"cluster remotely over its API, use community.general.proxmox_kvm instead. List VMs with " +
		"the read-only virt_facts module."
}

func (m *QM) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"vmid":    stringProp("The Proxmox VM id, e.g. \"100\"."),
		"state":   stringEnumProp("Desired VM state.", "started", "stopped", "shutdown", "rebooted", "reset"),
		"dry_run": boolProp("When true, report what would change without issuing any mutating qm command (check_mode).", false),
	}, "vmid", "state")
}

func (m *QM) Writes() bool { return true }

func (m *QM) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	vmid, err := stringParam(params, "vmid", true, "")
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

	data := map[string]any{"vmid": vmid}
	changed := false

	switch state {
	case "started", "stopped", "shutdown":
		running, err := m.isRunning(ctx, vmid)
		if err != nil {
			return Result{}, err
		}
		data["was_running"] = running
		wantRunning := state == "started"
		// stopped/shutdown both target "not running".
		if running != wantRunning {
			changed = true
			if !dryRun {
				action := map[string]string{"started": "start", "stopped": "stop", "shutdown": "shutdown"}[state]
				if _, err := m.Runner(ctx, "qm", action, vmid); err != nil {
					return Result{}, fmt.Errorf("qm: %s %s: %w", action, vmid, err)
				}
			}
		}
	case "rebooted", "reset":
		changed = true
		if !dryRun {
			action := map[string]string{"rebooted": "reboot", "reset": "reset"}[state]
			if _, err := m.Runner(ctx, "qm", action, vmid); err != nil {
				return Result{}, fmt.Errorf("qm: %s %s: %w", action, vmid, err)
			}
		}
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want started|stopped|shutdown|rebooted|reset)", state)
	}

	return Result{Changed: changed, Msg: "state applied", Data: data}, nil
}

// isRunning reports whether `qm status <vmid>` says "status: running".
func (m *QM) isRunning(ctx context.Context, vmid string) (bool, error) {
	out, err := m.Runner(ctx, "qm", "status", vmid)
	if err != nil {
		return false, fmt.Errorf("qm: querying status for %s: %w", vmid, err)
	}
	return strings.Contains(string(out), "status: running"), nil
}
