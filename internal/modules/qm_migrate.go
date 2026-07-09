package modules

import (
	"context"
	"fmt"
)

// QMMigrate migrates a Proxmox VE VM to another cluster node via the local
// `qm migrate` CLI. Migration is an action (not a state comparison), so it
// always reports changed=true on a real run. Runner is injectable.
type QMMigrate struct {
	Runner CommandRunner
}

// NewQMMigrate returns a QMMigrate module backed by the real qm CLI.
func NewQMMigrate() *QMMigrate { return &QMMigrate{Runner: defaultCommandRunner} }

func (m *QMMigrate) Name() string { return "qm_migrate" }

func (m *QMMigrate) Description() string {
	return "" +
		"Migrate a Proxmox VE VM to another cluster node via the local `qm migrate <vmid> " +
		"<target>` CLI. online=true does a live migration (qm migrate --online); " +
		"with_local_disks=true also moves local disks (--with-local-disks). An action, not a " +
		"state — always changed on a real run. check_mode via dry_run=true issues no command. " +
		"Requires vmid + target (the destination node name).\n\n" +
		"Local-node counterpart to the API-based Proxmox migration; VM power/snapshot are the " +
		"separate qm / qm_snapshot modules."
}

func (m *QMMigrate) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"vmid":             stringProp("The Proxmox VM id to migrate, e.g. \"100\"."),
		"target":           stringProp("Destination Proxmox node name."),
		"online":           boolProp("Live migration (--online). Default false.", false),
		"with_local_disks": boolProp("Also migrate local disks (--with-local-disks). Default false.", false),
		"dry_run":          boolProp("When true, report what would happen without migrating.", false),
	}, "vmid", "target")
}

func (m *QMMigrate) Writes() bool { return true }

func (m *QMMigrate) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	vmid, err := stringParam(params, "vmid", true, "")
	if err != nil {
		return Result{}, err
	}
	target, err := stringParam(params, "target", true, "")
	if err != nil {
		return Result{}, err
	}
	online, err := boolParam(params, "online", false)
	if err != nil {
		return Result{}, err
	}
	withLocalDisks, err := boolParam(params, "with_local_disks", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	args := []string{"migrate", vmid, target}
	if online {
		args = append(args, "--online")
	}
	if withLocalDisks {
		args = append(args, "--with-local-disks")
	}

	data := map[string]any{"vmid": vmid, "target": target, "online": online}
	if !dryRun {
		if _, err := m.Runner(ctx, "qm", args...); err != nil {
			return Result{}, fmt.Errorf("qm: migrate %s -> %s: %w", vmid, target, err)
		}
	}
	return Result{Changed: true, Msg: fmt.Sprintf("migrated %s to %s", vmid, target), Data: data}, nil
}
