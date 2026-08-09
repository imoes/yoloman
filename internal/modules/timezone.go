package modules

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// ReadlinkFunc resolves a symlink's target. Injectable for testing (real
// implementation: os.Readlink).
type ReadlinkFunc func(path string) (string, error)

// Timezone ensures the system timezone matches a desired value, mirroring
// ansible.builtin.timezone. It targets systemd-based Linux, like the rest
// of this agent's write modules: timedatectl sets the timezone, and
// /etc/localtime's symlink target (conventionally
// /usr/share/zoneinfo/<Area>/<Location>) is read directly to check the
// current value without shelling out.
type Timezone struct {
	Runner   CommandRunner
	Readlink ReadlinkFunc
}

// NewTimezone returns a Timezone module backed by the real timedatectl
// binary and os.Readlink.
func NewTimezone() *Timezone {
	return &Timezone{Runner: defaultCommandRunner, Readlink: os.Readlink}
}

func (t *Timezone) Name() string { return "timezone" }

func (t *Timezone) Description() string {
	return "" +
		"Ensure the system timezone matches a desired IANA zone name (e.g. \"Europe/Berlin\", " +
		"\"UTC\"), using timedatectl (systemd-based Linux, like the rest of this agent). " +
		"Idempotent — reads /etc/localtime's symlink target to determine the current zone " +
		"before deciding whether timedatectl needs to run. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.timezone. Same name parameter; Ansible supports multiple " +
		"per-distro strategies, this module only implements the systemd (timedatectl) " +
		"strategy.\n" +
		"- Chef: no single built-in resource; typically a `execute` resource wrapping " +
		"timedatectl, or the community 'timezone_ii'/'timezone' cookbooks.\n" +
		"- Puppet: the puppetlabs 'timezone' or saz-timezone third-party modules — no core " +
		"equivalent.\n" +
		"- Salt: the `timezone.system` state.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's kernel/system " +
		"clock configuration."
}

func (t *Timezone) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Desired IANA timezone name, e.g. "Europe/Berlin" or "UTC".`),
		"dry_run": boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (t *Timezone) Writes() bool { return true }

func (t *Timezone) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	current, err := t.currentTimezone()
	if err != nil {
		return Result{}, fmt.Errorf("timezone: reading current timezone: %w", err)
	}

	if current == name {
		return Result{Changed: false, Msg: "timezone already set", Data: map[string]any{"name": name}}, nil
	}

	if !dryRun {
		if _, err := t.Runner(ctx, "timedatectl", "set-timezone", name); err != nil {
			return Result{}, fmt.Errorf("timezone: setting %q: %w", name, err)
		}
	}
	return Result{Changed: true, Msg: "timezone updated", Data: map[string]any{"name": name, "previous": current}}, nil
}

// currentTimezone extracts the IANA zone name from /etc/localtime's symlink
// target, e.g. "/usr/share/zoneinfo/Europe/Berlin" -> "Europe/Berlin".
func (t *Timezone) currentTimezone() (string, error) {
	target, err := t.Readlink("/etc/localtime")
	if err != nil {
		return "", err
	}
	const marker = "zoneinfo/"
	idx := strings.LastIndex(target, marker)
	if idx == -1 {
		return "", fmt.Errorf("unrecognized /etc/localtime target %q", target)
	}
	return target[idx+len(marker):], nil
}
