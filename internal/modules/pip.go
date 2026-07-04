package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Pip manages Python package presence via pip, mirroring
// ansible.builtin.pip. Idempotent: queries `pip show <pkg>` before deciding
// whether to act. Runner is injectable for testing.
type Pip struct {
	Runner CommandRunner
}

// NewPip returns a Pip module backed by the real pip binary.
func NewPip() *Pip { return &Pip{Runner: defaultCommandRunner} }

func (p *Pip) Name() string { return "pip" }

func (p *Pip) Description() string {
	return "" +
		"Ensure one or more Python packages are present, absent, or upgraded to the latest " +
		"available version, via pip. Idempotent: queries `pip show <pkg>` (a read-only query, " +
		"safe under check_mode) before deciding whether to act. A package spec may pin an exact " +
		"version with \"pkg==1.2.3\" (checked for state=present); state=latest always attempts " +
		"`pip install --upgrade` and reports changed based on the version actually observed " +
		"before vs. after. An optional `virtualenv` path is created via `python3 -m venv` if it " +
		"doesn't yet exist, and that venv's own pip is used instead of a system-wide one. " +
		"Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.pip. Same name/state/version/virtualenv parameter names (a " +
		"focused subset — Ansible also supports requirements files, extra_args, and more, not " +
		"implemented here).\n" +
		"- Chef: the `pip_package` resource (poise-python / python cookbook).\n" +
		"- Puppet: the puppet-python module's `package` type with `provider => pip`.\n" +
		"- Salt: the `pip.installed`/`pip.removed` states.\n" +
		"- Terraform: not applicable — Terraform does not manage language-level package managers " +
		"on a running host."
}

func (p *Pip) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":       stringArrayProp(`One or more package names, e.g. ["requests"] or ["requests==2.31.0"] (an "==version" suffix pins an exact version for state=present).`),
		"state":      stringEnumProp(`Desired package state. Default "present".`, "present", "absent", "latest"),
		"virtualenv": stringProp("Optional path to a virtualenv; created via `python3 -m venv` if it doesn't exist yet, and used instead of the system pip."),
		"executable": stringProp(`Pip binary to use when virtualenv is not set. Default "pip3".`),
		"dry_run":    boolProp("When true, report what would change without issuing any mutating pip command (check_mode).", false),
	}, "name")
}

func (p *Pip) Writes() bool { return true }

func (p *Pip) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	names, err := stringOrStringSliceParam(params, "name", true)
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	if state != "present" && state != "absent" && state != "latest" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent|latest)", state)
	}
	virtualenv, err := stringParam(params, "virtualenv", false, "")
	if err != nil {
		return Result{}, err
	}
	executable, err := stringParam(params, "executable", false, "pip3")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	pipBin := executable
	if virtualenv != "" {
		venvPip := filepath.Join(virtualenv, "bin", "pip")
		if _, err := os.Stat(venvPip); err != nil {
			if dryRun {
				return Result{Changed: true, Msg: "would create virtualenv and install packages (dry run)", Data: map[string]any{"virtualenv": virtualenv}}, nil
			}
			if _, err := p.Runner(ctx, "python3", "-m", "venv", virtualenv); err != nil {
				return Result{}, fmt.Errorf("pip: creating virtualenv %s: %w", virtualenv, err)
			}
		}
		pipBin = venvPip
	}

	changed := false
	var results []map[string]any
	for _, spec := range names {
		pkgName, pinnedVersion := splitPipSpec(spec)

		installed, version, err := p.pipShow(ctx, pipBin, pkgName)
		if err != nil {
			return Result{}, fmt.Errorf("pip: querying %s: %w", pkgName, err)
		}

		var pkgChanged bool
		switch state {
		case "present":
			if pinnedVersion != "" {
				pkgChanged = !installed || version != pinnedVersion
			} else {
				pkgChanged = !installed
			}
		case "absent":
			pkgChanged = installed
		case "latest":
			pkgChanged = true
		}

		if pkgChanged && !dryRun {
			switch state {
			case "present":
				if _, err := p.Runner(ctx, pipBin, "install", spec); err != nil {
					return Result{}, fmt.Errorf("pip: installing %s: %w", spec, err)
				}
			case "absent":
				if _, err := p.Runner(ctx, pipBin, "uninstall", "-y", pkgName); err != nil {
					return Result{}, fmt.Errorf("pip: uninstalling %s: %w", pkgName, err)
				}
			case "latest":
				if _, err := p.Runner(ctx, pipBin, "install", "--upgrade", pkgName); err != nil {
					return Result{}, fmt.Errorf("pip: upgrading %s: %w", pkgName, err)
				}
			}
		}

		if state == "latest" && !dryRun {
			_, afterVersion, err := p.pipShow(ctx, pipBin, pkgName)
			if err != nil {
				return Result{}, fmt.Errorf("pip: re-querying %s after upgrade: %w", pkgName, err)
			}
			pkgChanged = afterVersion != version
			version = afterVersion
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

// splitPipSpec splits a "pkg==1.2.3" spec into its package name and pinned
// version (empty if unpinned).
func splitPipSpec(spec string) (name, version string) {
	if idx := strings.Index(spec, "=="); idx >= 0 {
		return spec[:idx], spec[idx+2:]
	}
	return spec, ""
}

// pipShow reports whether pkg is currently installed and, if so, its
// version, via `pip show`. An unknown package is reported as not-installed
// rather than an error, since that's pip's normal (non-zero exit) response.
func (p *Pip) pipShow(ctx context.Context, pipBin, pkg string) (installed bool, version string, err error) {
	out, err := p.Runner(ctx, pipBin, "show", pkg)
	if err != nil {
		if isExitError(err) {
			return false, "", nil
		}
		return false, "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if v, ok := strings.CutPrefix(line, "Version: "); ok {
			return true, strings.TrimSpace(v), nil
		}
	}
	return true, "", nil
}
