package modules

import (
	"context"
	"fmt"
	"strings"
)

// Apt manages package presence via dpkg/apt-get, mirroring
// ansible.builtin.apt on Debian-family systems (the agent's primary
// packaging target). Runner is injectable for testing.
type Apt struct {
	Runner CommandRunner
}

// NewApt returns an Apt module backed by the real apt-get/dpkg-query.
func NewApt() *Apt { return &Apt{Runner: defaultCommandRunner} }

func (a *Apt) Name() string { return "apt" }

func (a *Apt) Description() string {
	return "" +
		"Ensure one or more Debian packages are present, absent, or upgraded to the latest " +
		"available version, via dpkg/apt-get. Idempotent: queries dpkg's current status (and, " +
		"for state=latest, apt-cache's candidate version — a read-only query, safe to run even " +
		"under check_mode) before deciding whether to act. Debian/Ubuntu only in v1. Supports " +
		"check_mode via dry_run=true (queries state but issues no apt-get mutation).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.apt. Same name/state/update_cache parameter names " +
		"(name accepts either a single package or a list); v1 is a focused subset — Ansible's " +
		"apt also supports upgrade, autoremove, deb, and more, not yet implemented here.\n" +
		"- Chef: the `apt_package` resource — `action :install`/`:remove`/`:upgrade`.\n" +
		"- Puppet: the `package` type with `provider => apt` — `ensure => present`/`absent`/" +
		"`latest`.\n" +
		"- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.\n" +
		"- Terraform: not applicable — Terraform does not manage OS packages on a running host; " +
		"this would normally be done via a provisioner or left to configuration management " +
		"entirely."
}

func (a *Apt) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":         stringArrayProp(`One or more package names, e.g. ["nginx"] or ["nginx", "curl=8.5.0-2ubuntu10"] (an "=version" suffix pins a specific version for state=present).`),
		"state":        stringEnumProp(`Desired package state. Default "present".`, "present", "absent", "latest"),
		"update_cache": boolProp("Whether to run `apt-get update` before evaluating package state. Default false.", false),
		"dry_run":      boolProp("When true, report what would change without issuing any mutating apt-get command (check_mode).", false),
	}, "name")
}

func (a *Apt) Writes() bool { return true }

func (a *Apt) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	names, err := stringOrStringSliceParam(params, "name", true)
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	updateCache, err := boolParam(params, "update_cache", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun
	if state != "present" && state != "absent" && state != "latest" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent|latest)", state)
	}

	if updateCache && !dryRun {
		if _, err := a.Runner(ctx, "apt-get", "update"); err != nil {
			return Result{}, fmt.Errorf("apt: update_cache: %w", err)
		}
	}

	changed := false
	var results []map[string]any
	for _, spec := range names {
		pkgName := spec
		if idx := strings.IndexByte(spec, '='); idx >= 0 {
			pkgName = spec[:idx]
		}

		installed, version, err := a.dpkgStatus(ctx, pkgName)
		if err != nil {
			return Result{}, fmt.Errorf("apt: querying %s: %w", pkgName, err)
		}

		var pkgChanged bool
		var action string
		switch state {
		case "present":
			pkgChanged = !installed
			action = "install"
		case "absent":
			pkgChanged = installed
			action = "remove"
		case "latest":
			candidate, err := a.candidateVersion(ctx, pkgName)
			if err != nil {
				return Result{}, fmt.Errorf("apt: querying candidate for %s: %w", pkgName, err)
			}
			pkgChanged = !installed || (candidate != "" && candidate != version)
			action = "install"
		}

		if pkgChanged && !dryRun {
			args := []string{action, "-y"}
			if action == "install" {
				args = append(args, spec)
			} else {
				args = append(args, pkgName)
			}
			if _, err := a.Runner(ctx, "apt-get", args...); err != nil {
				return Result{}, fmt.Errorf("apt: %sing %s: %w", action, pkgName, err)
			}
		}

		changed = changed || pkgChanged
		results = append(results, map[string]any{
			"name":              pkgName,
			"installed_version": version,
			"changed":           pkgChanged,
		})
	}

	return Result{Changed: changed, Msg: "package state applied", Data: results}, nil
}

// dpkgStatus reports whether pkg is currently installed and, if so, its
// version. An unknown package is reported as not-installed rather than an
// error, since that's dpkg-query's normal (non-zero exit) response to it.
func (a *Apt) dpkgStatus(ctx context.Context, pkg string) (installed bool, version string, err error) {
	out, err := a.Runner(ctx, "dpkg-query", "-W", "-f", "${Status}\t${Version}", pkg)
	if err != nil {
		if isExitError(err) {
			return false, "", nil
		}
		return false, "", err
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), "\t", 2)
	status := parts[0]
	if len(parts) > 1 {
		version = parts[1]
	}
	installed = strings.Contains(status, "installed")
	return installed, version, nil
}

// candidateVersion returns the apt-cache policy "Candidate" version for pkg,
// or "" if apt-cache reports no candidate (e.g. package not found in any
// configured repository). This is a read-only query, safe to run even
// during dry_run.
func (a *Apt) candidateVersion(ctx context.Context, pkg string) (string, error) {
	out, err := a.Runner(ctx, "apt-cache", "policy", pkg)
	if err != nil {
		if isExitError(err) {
			return "", nil
		}
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Candidate:") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "Candidate:"))
			if v == "(none)" {
				return "", nil
			}
			return v, nil
		}
	}
	return "", nil
}
