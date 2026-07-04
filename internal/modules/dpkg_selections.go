package modules

import (
	"context"
	"fmt"
	"strings"
)

// DpkgSelections sets a package's dpkg selection state (e.g. "hold" to
// prevent it from being upgraded), mirroring ansible.builtin.dpkg_selections.
// It is idempotent: it checks the current selection via
// `dpkg --get-selections` before deciding whether to change it.
type DpkgSelections struct {
	Runner      CommandRunner
	RunnerStdin CommandRunnerWithStdin
}

// NewDpkgSelections returns a DpkgSelections module backed by the real dpkg
// binary.
func NewDpkgSelections() *DpkgSelections {
	return &DpkgSelections{Runner: defaultCommandRunner, RunnerStdin: defaultCommandRunnerWithStdin}
}

func (d *DpkgSelections) Name() string { return "dpkg_selections" }

func (d *DpkgSelections) Description() string {
	return "" +
		"Set a Debian/Ubuntu package's dpkg selection state — most commonly \"hold\", to " +
		"prevent apt from ever upgrading/removing it even when a newer version is available. " +
		"Idempotent — checks the package's current selection via `dpkg --get-selections` first " +
		"and only calls `dpkg --set-selections` when it differs. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.dpkg_selections. Same name/selection parameters.\n" +
		"- Chef: the `dpkg_autostart`/`apt_preference` resources approximate parts of this; " +
		"the closest direct equivalent is shelling out to `dpkg --set-selections` in a " +
		"custom resource.\n" +
		"- Puppet: the `package` type's `hold` provider-specific ensure value on Debian " +
		"systems (`ensure => held`).\n" +
		"- Salt: the `pkg.held`/`pkg.unheld` states.\n" +
		"- Terraform: not applicable — Terraform does not manage OS package hold state."
}

func (d *DpkgSelections) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":      stringProp(`Package name, e.g. "curl".`),
		"selection": stringEnumProp("Desired dpkg selection state.", "install", "hold", "deinstall", "purge"),
		"dry_run":   boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name", "selection")
}

func (d *DpkgSelections) Writes() bool { return true }

func (d *DpkgSelections) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	selection, err := stringParam(params, "selection", true, "")
	if err != nil {
		return Result{}, err
	}
	switch selection {
	case "install", "hold", "deinstall", "purge":
	default:
		return Result{}, fmt.Errorf("selection: unsupported value %q (want install|hold|deinstall|purge)", selection)
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	current, err := d.currentSelection(ctx, name)
	if err != nil {
		return Result{}, err
	}

	if current == selection {
		return Result{Changed: false, Msg: "selection already set", Data: map[string]any{"name": name, "selection": selection}}, nil
	}

	if !dryRun {
		stdin := name + "\t" + selection + "\n"
		if _, err := d.RunnerStdin(ctx, stdin, "dpkg", "--set-selections"); err != nil {
			return Result{}, fmt.Errorf("dpkg_selections: setting %s to %s: %w", name, selection, err)
		}
	}
	return Result{Changed: true, Msg: "selection updated", Data: map[string]any{"name": name, "selection": selection, "previous": current}}, nil
}

// currentSelection returns name's current dpkg selection state, or
// "unknown" if dpkg has no record of it (a package that was never
// explicitly selected/installed).
func (d *DpkgSelections) currentSelection(ctx context.Context, name string) (string, error) {
	out, err := d.Runner(ctx, "dpkg", "--get-selections", name)
	if err != nil {
		// dpkg --get-selections exits non-zero (with no output) when the
		// package has no selection recorded at all yet.
		return "unknown", nil
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 2 {
		return "unknown", nil
	}
	return fields[1], nil
}
