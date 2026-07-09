package modules

import (
	"context"
	"fmt"
	"strings"
)

// QMSnapshot manages Proxmox VE VM snapshots via the local `qm` CLI:
// create (qm snapshot), delete (qm delsnapshot), and rollback (qm rollback),
// idempotent for present/absent via `qm listsnapshot`. Runner is injectable.
type QMSnapshot struct {
	Runner CommandRunner
}

// NewQMSnapshot returns a QMSnapshot module backed by the real qm CLI.
func NewQMSnapshot() *QMSnapshot { return &QMSnapshot{Runner: defaultCommandRunner} }

func (m *QMSnapshot) Name() string { return "qm_snapshot" }

func (m *QMSnapshot) Description() string {
	return "" +
		"Manage a Proxmox VE VM snapshot on this node via the local `qm` CLI. state: present " +
		"(qm snapshot — create if missing, idempotent), absent (qm delsnapshot — remove if " +
		"present, idempotent), rollback (qm rollback — always acts). Existence is checked with " +
		"`qm listsnapshot <vmid>`. Optional description; vmstate=true also snapshots the VM's RAM. " +
		"check_mode via dry_run=true. Requires vmid + snapname.\n\n" +
		"Mirrors community.general.proxmox_snap but drives the node locally. Reboot/power state is " +
		"the separate `qm` module; migration is `qm_migrate`."
}

func (m *QMSnapshot) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"vmid":        stringProp("The Proxmox VM id, e.g. \"100\"."),
		"snapname":    stringProp("Snapshot name."),
		"state":       stringEnumProp("Desired snapshot state.", "present", "absent", "rollback"),
		"description": stringProp("Optional snapshot description (state=present)."),
		"vmstate":     boolProp("Also snapshot the VM RAM/running state (state=present).", false),
		"dry_run":     boolProp("When true, report what would change without issuing any mutating qm command.", false),
	}, "vmid", "snapname", "state")
}

func (m *QMSnapshot) Writes() bool { return true }

func (m *QMSnapshot) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	vmid, err := stringParam(params, "vmid", true, "")
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
	vmstate, err := boolParam(params, "vmstate", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	data := map[string]any{"vmid": vmid, "snapname": snapname}

	switch state {
	case "rollback":
		if !dryRun {
			if _, err := m.Runner(ctx, "qm", "rollback", vmid, snapname); err != nil {
				return Result{}, fmt.Errorf("qm: rollback %s@%s: %w", vmid, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "rolled back", Data: data}, nil
	case "present":
		exists, err := m.snapshotExists(ctx, vmid, snapname)
		if err != nil {
			return Result{}, err
		}
		if exists {
			return Result{Changed: false, Msg: "snapshot already present", Data: data}, nil
		}
		if !dryRun {
			args := []string{"snapshot", vmid, snapname}
			if description != "" {
				args = append(args, "--description", description)
			}
			if vmstate {
				args = append(args, "--vmstate", "1")
			}
			if _, err := m.Runner(ctx, "qm", args...); err != nil {
				return Result{}, fmt.Errorf("qm: snapshot %s@%s: %w", vmid, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "snapshot created", Data: data}, nil
	case "absent":
		exists, err := m.snapshotExists(ctx, vmid, snapname)
		if err != nil {
			return Result{}, err
		}
		if !exists {
			return Result{Changed: false, Msg: "snapshot already absent", Data: data}, nil
		}
		if !dryRun {
			if _, err := m.Runner(ctx, "qm", "delsnapshot", vmid, snapname); err != nil {
				return Result{}, fmt.Errorf("qm: delsnapshot %s@%s: %w", vmid, snapname, err)
			}
		}
		return Result{Changed: true, Msg: "snapshot removed", Data: data}, nil
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent|rollback)", state)
	}
}

// snapshotExists reports whether snapname appears in `qm listsnapshot <vmid>`.
// The output is a tree (leading `->`, backtick, whitespace); the snapshot name
// is the first token of each entry, ignoring the "current" pseudo-entry.
func (m *QMSnapshot) snapshotExists(ctx context.Context, vmid, snapname string) (bool, error) {
	out, err := m.Runner(ctx, "qm", "listsnapshot", vmid)
	if err != nil {
		return false, fmt.Errorf("qm: listsnapshot %s: %w", vmid, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimLeft(line, " `->")
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if f[0] == snapname {
			return true, nil
		}
	}
	return false, nil
}
