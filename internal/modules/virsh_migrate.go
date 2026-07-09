package modules

import (
	"context"
	"fmt"
)

// VirshMigrate migrates a libvirt/KVM domain to another host via the local
// `virsh migrate` CLI. An action (not a state comparison), so it always
// reports changed=true on a real run. Runner is injectable.
type VirshMigrate struct {
	Runner CommandRunner
}

// NewVirshMigrate returns a VirshMigrate module backed by the real virsh CLI.
func NewVirshMigrate() *VirshMigrate { return &VirshMigrate{Runner: defaultCommandRunner} }

func (m *VirshMigrate) Name() string { return "virsh_migrate" }

func (m *VirshMigrate) Description() string {
	return "" +
		"Migrate a libvirt/KVM domain to another host via the local `virsh migrate` CLI. " +
		"dest_uri is the destination libvirt connection URI, e.g. qemu+ssh://node2/system. " +
		"live=true does a live migration (--live). An action, not a state — always changed on a " +
		"real run. check_mode via dry_run=true issues no command. Requires domain + dest_uri."
}

func (m *VirshMigrate) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"domain":   stringProp("The libvirt domain name to migrate."),
		"dest_uri": stringProp("Destination libvirt URI, e.g. qemu+ssh://node2/system."),
		"live":     boolProp("Live migration (--live). Default false.", false),
		"dry_run":  boolProp("When true, report what would happen without migrating.", false),
	}, "domain", "dest_uri")
}

func (m *VirshMigrate) Writes() bool { return true }

func (m *VirshMigrate) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	domain, err := stringParam(params, "domain", true, "")
	if err != nil {
		return Result{}, err
	}
	destURI, err := stringParam(params, "dest_uri", true, "")
	if err != nil {
		return Result{}, err
	}
	live, err := boolParam(params, "live", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	args := []string{"migrate"}
	if live {
		args = append(args, "--live")
	}
	args = append(args, domain, destURI)

	data := map[string]any{"domain": domain, "dest_uri": destURI, "live": live}
	if !dryRun {
		if _, err := m.Runner(ctx, "virsh", args...); err != nil {
			return Result{}, fmt.Errorf("virsh: migrate %s -> %s: %w", domain, destURI, err)
		}
	}
	return Result{Changed: true, Msg: fmt.Sprintf("migrated %s to %s", domain, destURI), Data: data}, nil
}
