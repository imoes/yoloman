package modules

import (
	"context"
	"fmt"
	"path/filepath"
)

// Sysvinit manages a legacy SysV init script's running and enabled-at-boot
// state, mirroring ansible.builtin.sysvinit. It targets hosts (or
// individual services) still using /etc/init.d scripts rather than
// systemd — the agent's primary target is systemd (see systemd.go/service),
// but this module exists for the same completeness reason apt/yum both
// exist despite the agent favoring neither distro family.
type Sysvinit struct {
	Runner  CommandRunner
	InitDir string   // directory containing init scripts, default "/etc/init.d"
	RcDirs  []string // runlevel directories searched for an "enabled" symlink
}

// NewSysvinit returns a Sysvinit module backed by the real /etc/init.d
// scripts and update-rc.d.
func NewSysvinit() *Sysvinit {
	return &Sysvinit{
		Runner:  defaultCommandRunner,
		InitDir: "/etc/init.d",
		RcDirs:  []string{"/etc/rc2.d", "/etc/rc3.d", "/etc/rc4.d", "/etc/rc5.d"},
	}
}

func (s *Sysvinit) Name() string { return "sysvinit" }

func (s *Sysvinit) Description() string {
	return "" +
		"Manage a legacy SysV init script's running state (start/stop/restart/reload) and its " +
		"enabled-at-boot state, via /etc/init.d/<name> and update-rc.d. Idempotent: queries the " +
		"init script's own \"status\" action (LSB convention: exit 0 means running) and the " +
		"presence of an S## runlevel symlink before deciding whether to act — except " +
		"state=restarted/reloaded, always treated as changed, matching systemd's module " +
		"behavior for the same reason. Supports check_mode via dry_run=true. This agent's " +
		"primary target is systemd (see the systemd/service modules); sysvinit exists for hosts " +
		"or individual services that still predate it.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.sysvinit. Same name/state/enabled parameter names.\n" +
		"- Chef: the `service` resource with `provider Chef::Provider::Service::Init`.\n" +
		"- Puppet: the `service` type with `provider => init`.\n" +
		"- Salt: the `service.running`/`service.dead` states with the init provider selected.\n" +
		"- Terraform: not applicable — see the systemd module's description for the general " +
		"reasoning (Terraform does not manage live service state on a running host)."
}

func (s *Sysvinit) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Init script name under /etc/init.d, e.g. "nginx".`),
		"state":   stringEnumProp(`Desired running state. Omit to only manage "enabled" without touching running state.`, "started", "stopped", "restarted", "reloaded"),
		"enabled": boolProp("Whether the service should start at boot. Omit to leave the current enabled state untouched.", false),
		"dry_run": boolProp("When true, report what would change without issuing any mutating command (check_mode).", false),
	}, "name")
}

func (s *Sysvinit) Writes() bool { return true }

func (s *Sysvinit) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "")
	if err != nil {
		return Result{}, err
	}
	_, enabledGiven := params["enabled"]
	enabled, err := boolParam(params, "enabled", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	script := filepath.Join(s.InitDir, name)
	changed := false
	data := map[string]any{"name": name}

	switch state {
	case "":
		// enabled-only management, handled below
	case "started":
		active, err := s.isActive(ctx, script)
		if err != nil {
			return Result{}, err
		}
		data["was_active"] = active
		if !active {
			changed = true
			if !dryRun {
				if _, err := s.Runner(ctx, script, "start"); err != nil {
					return Result{}, fmt.Errorf("sysvinit: starting %s: %w", name, err)
				}
			}
		}
	case "stopped":
		active, err := s.isActive(ctx, script)
		if err != nil {
			return Result{}, err
		}
		data["was_active"] = active
		if active {
			changed = true
			if !dryRun {
				if _, err := s.Runner(ctx, script, "stop"); err != nil {
					return Result{}, fmt.Errorf("sysvinit: stopping %s: %w", name, err)
				}
			}
		}
	case "restarted":
		changed = true
		if !dryRun {
			if _, err := s.Runner(ctx, script, "restart"); err != nil {
				return Result{}, fmt.Errorf("sysvinit: restarting %s: %w", name, err)
			}
		}
	case "reloaded":
		changed = true
		if !dryRun {
			if _, err := s.Runner(ctx, script, "reload"); err != nil {
				return Result{}, fmt.Errorf("sysvinit: reloading %s: %w", name, err)
			}
		}
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want started|stopped|restarted|reloaded)", state)
	}

	if enabledGiven {
		curEnabled := s.isEnabled(name)
		data["was_enabled"] = curEnabled
		if curEnabled != enabled {
			changed = true
			if !dryRun {
				action := "disable"
				if enabled {
					action = "enable"
				}
				if _, err := s.Runner(ctx, "update-rc.d", name, action); err != nil {
					return Result{}, fmt.Errorf("sysvinit: %sing %s: %w", action, name, err)
				}
			}
		}
	}

	return Result{Changed: changed, Msg: "state applied", Data: data}, nil
}

// isActive runs the init script's "status" action. Per LSB convention, exit
// 0 means the service is running; any other exit means it isn't (or the
// script doesn't implement status meaningfully — treated the same as "not
// running", matching the systemd module's read of is-active).
func (s *Sysvinit) isActive(ctx context.Context, script string) (bool, error) {
	_, err := s.Runner(ctx, script, "status")
	if err != nil && !isExitError(err) {
		return false, fmt.Errorf("sysvinit: querying status of %s: %w", script, err)
	}
	return err == nil, nil
}

// isEnabled reports whether name has an S## runlevel symlink in any of the
// configured RcDirs.
func (s *Sysvinit) isEnabled(name string) bool {
	for _, dir := range s.RcDirs {
		matches, _ := filepath.Glob(filepath.Join(dir, "S[0-9][0-9]"+name))
		if len(matches) > 0 {
			return true
		}
	}
	return false
}
