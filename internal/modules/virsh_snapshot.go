package modules

import (
	"context"
	"fmt"
	"strings"
)

// VirshSnapshot manages libvirt/KVM domain snapshots via the local `virsh`
// CLI: create (snapshot-create-as), delete (snapshot-delete), and revert
// (snapshot-revert), idempotent for present/absent via `virsh snapshot-list`.
type VirshSnapshot struct {
	Runner CommandRunner
}

// NewVirshSnapshot returns a VirshSnapshot module backed by the real virsh CLI.
func NewVirshSnapshot() *VirshSnapshot { return &VirshSnapshot{Runner: defaultCommandRunner} }

func (m *VirshSnapshot) Name() string { return "virsh_snapshot" }

func (m *VirshSnapshot) Description() string {
	return "" +
		"Manage a libvirt/KVM domain snapshot via the local `virsh` CLI. state: present " +
		"(virsh snapshot-create-as — create if missing, idempotent), absent (virsh " +
		"snapshot-delete — remove if present, idempotent), revert (virsh snapshot-revert — " +
		"always acts). Existence is checked with `virsh snapshot-list <domain> --name`. Optional " +
		"description. check_mode via dry_run=true. Requires domain + snapname."
}

func (m *VirshSnapshot) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"domain":      stringProp("The libvirt domain name."),
		"snapname":    stringProp("Snapshot name."),
		"state":       stringEnumProp("Desired snapshot state.", "present", "absent", "revert"),
		"description": stringProp("Optional snapshot description (state=present)."),
		"dry_run":     boolProp("When true, report what would change without issuing any mutating command.", false),
	}, "domain", "snapname", "state")
}

func (m *VirshSnapshot) Writes() bool { return true }

func (m *VirshSnapshot) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	domain, err := stringParam(params, "domain", true, "")
	if err != nil {
		return Result{}, err
	}
	snapname, err := stringParam(params, "snapname", true, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", true, "")
	if err != nil {
		return Result{}, err
	}
	description, err := stringParam(params, "description", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	data := map[string]any{"domain": domain, "snapname": snapname}

	switch state {
	case "revert":
		if !dryRun {
			if _, err := m.Runner(ctx, "virsh", "snapshot-revert", domain, snapname); err != nil {
				return Result{}, fmt.Errorf("virsh: snapshot-revert %s@%s: %w", domain, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "reverted", Data: data}, nil
	case "present":
		exists, err := m.snapshotExists(ctx, domain, snapname)
		if err != nil {
			return Result{}, err
		}
		if exists {
			return Result{Changed: false, Msg: "snapshot already present", Data: data}, nil
		}
		if !dryRun {
			args := []string{"snapshot-create-as", domain, snapname}
			if description != "" {
				args = append(args, "--description", description)
			}
			if _, err := m.Runner(ctx, "virsh", args...); err != nil {
				return Result{}, fmt.Errorf("virsh: snapshot-create-as %s@%s: %w", domain, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "snapshot created", Data: data}, nil
	case "absent":
		exists, err := m.snapshotExists(ctx, domain, snapname)
		if err != nil {
			return Result{}, err
		}
		if !exists {
			return Result{Changed: false, Msg: "snapshot already absent", Data: data}, nil
		}
		if !dryRun {
			if _, err := m.Runner(ctx, "virsh", "snapshot-delete", domain, snapname); err != nil {
				return Result{}, fmt.Errorf("virsh: snapshot-delete %s@%s: %w", domain, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "snapshot removed", Data: data}, nil
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent|revert)", state)
	}
}

// snapshotExists reports whether snapname appears in the one-name-per-line
// output of `virsh snapshot-list <domain> --name`.
func (m *VirshSnapshot) snapshotExists(ctx context.Context, domain, snapname string) (bool, error) {
	out, err := m.Runner(ctx, "virsh", "snapshot-list", domain, "--name")
	if err != nil {
		return false, fmt.Errorf("virsh: snapshot-list %s: %w", domain, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == snapname {
			return true, nil
		}
	}
	return false, nil
}
