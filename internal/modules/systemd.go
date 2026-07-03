package modules

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Systemd manages a systemd unit's running and enabled state, mirroring
// ansible.builtin.systemd(_service). Runner is injectable for testing.
type Systemd struct {
	Runner CommandRunner
}

// NewSystemd returns a Systemd module backed by the real systemctl.
func NewSystemd() *Systemd { return &Systemd{Runner: defaultCommandRunner} }

func (s *Systemd) Name() string { return "systemd" }

func (s *Systemd) Description() string {
	return "" +
		"Manage a systemd unit's running state (start/stop/restart/reload) and its enabled-at-" +
		"boot state. Idempotent: queries `systemctl is-active`/`is-enabled` first and only " +
		"issues a mutating systemctl command when the current state differs from the desired " +
		"one — except state=restarted/reloaded, which Ansible (and this module) always treat " +
		"as changed, since a restart is inherently an action rather than a state comparison. " +
		"Supports check_mode via dry_run=true (queries current state but issues no systemctl " +
		"mutation).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.systemd / ansible.builtin.systemd_service (systemd-specific), " +
		"or the generic ansible.builtin.service module (dispatches to systemd on modern Linux). " +
		"Same name/state/enabled parameter names and state vocabulary.\n" +
		"- Chef: the `service` resource — `action :start`/`:stop`/`:restart`/`:reload` for " +
		"running state, `action :enable`/`:disable` for boot state.\n" +
		"- Puppet: the `service` type — `ensure => running`/`stopped`, `enable => true/false`.\n" +
		"- Salt: the `service.running`/`service.dead` states, with `enable: true/false`.\n" +
		"- Terraform: not applicable — Terraform does not manage live service state on a " +
		"running host; this is normally done via a provisioner or left to configuration " +
		"management entirely."
}

func (s *Systemd) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Unit name, e.g. "nginx" or "nginx.service" (the .service suffix is added automatically if omitted).`),
		"state":   stringEnumProp(`Desired running state. Omit to only manage "enabled" without touching running state.`, "started", "stopped", "restarted", "reloaded"),
		"enabled": boolProp("Whether the unit should start at boot. Omit to leave the current enabled state untouched.", false),
		"dry_run": boolProp("When true, report what would change without issuing any mutating systemctl command (check_mode).", false),
	}, "name")
}

func (s *Systemd) Writes() bool { return true }

func (s *Systemd) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
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

	unit := name
	if !strings.Contains(unit, ".") {
		unit += ".service"
	}

	changed := false
	data := map[string]any{"unit": unit}

	switch state {
	case "":
		// enabled-only management, handled below
	case "started":
		active, err := s.isActive(ctx, unit)
		if err != nil {
			return Result{}, err
		}
		data["was_active"] = active
		if !active {
			changed = true
			if !dryRun {
				if _, err := s.Runner(ctx, "systemctl", "start", unit); err != nil {
					return Result{}, fmt.Errorf("systemd: starting %s: %w", unit, err)
				}
			}
		}
	case "stopped":
		active, err := s.isActive(ctx, unit)
		if err != nil {
			return Result{}, err
		}
		data["was_active"] = active
		if active {
			changed = true
			if !dryRun {
				if _, err := s.Runner(ctx, "systemctl", "stop", unit); err != nil {
					return Result{}, fmt.Errorf("systemd: stopping %s: %w", unit, err)
				}
			}
		}
	case "restarted":
		changed = true
		if !dryRun {
			if _, err := s.Runner(ctx, "systemctl", "restart", unit); err != nil {
				return Result{}, fmt.Errorf("systemd: restarting %s: %w", unit, err)
			}
		}
	case "reloaded":
		changed = true
		if !dryRun {
			if _, err := s.Runner(ctx, "systemctl", "reload", unit); err != nil {
				return Result{}, fmt.Errorf("systemd: reloading %s: %w", unit, err)
			}
		}
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want started|stopped|restarted|reloaded)", state)
	}

	if enabledGiven {
		curEnabled, err := s.isEnabled(ctx, unit)
		if err != nil {
			return Result{}, err
		}
		data["was_enabled"] = curEnabled
		if curEnabled != enabled {
			changed = true
			if !dryRun {
				action := "disable"
				if enabled {
					action = "enable"
				}
				if _, err := s.Runner(ctx, "systemctl", action, unit); err != nil {
					return Result{}, fmt.Errorf("systemd: %sing %s: %w", action, unit, err)
				}
			}
		}
	}

	return Result{Changed: changed, Msg: "state applied", Data: data}, nil
}

func (s *Systemd) isActive(ctx context.Context, unit string) (bool, error) {
	out, err := s.Runner(ctx, "systemctl", "is-active", unit)
	if err != nil && !isExitError(err) {
		return false, fmt.Errorf("systemd: querying is-active for %s: %w", unit, err)
	}
	return strings.TrimSpace(string(out)) == "active", nil
}

func (s *Systemd) isEnabled(ctx context.Context, unit string) (bool, error) {
	out, err := s.Runner(ctx, "systemctl", "is-enabled", unit)
	if err != nil && !isExitError(err) {
		return false, fmt.Errorf("systemd: querying is-enabled for %s: %w", unit, err)
	}
	return strings.TrimSpace(string(out)) == "enabled", nil
}

// isExitError reports whether err is a nonzero process exit (as opposed to a
// failure to run the command at all, e.g. systemctl missing). systemctl
// is-active/is-enabled exit non-zero for a normal "inactive"/"disabled"
// answer, which is expected data, not a failure.
func isExitError(err error) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr)
}

// Service is a thin alias for Systemd under Ansible's more commonly used
// generic module name ("service" dispatches to systemd on modern Linux;
// this agent only targets systemd hosts, so it is a direct pass-through).
type Service struct{ *Systemd }

// NewService returns a Service module (alias of Systemd) backed by the real
// systemctl.
func NewService() *Service { return &Service{Systemd: NewSystemd()} }

func (s *Service) Name() string { return "service" }

func (s *Service) Description() string {
	return "" +
		"Alias of the systemd module under Ansible's more commonly used generic module name. " +
		"ansible.builtin.service dispatches to systemd, sysvinit, upstart, or other init " +
		"systems depending on the target's facts; this agent only targets systemd-based Linux, " +
		"so `service` and `systemd` behave identically here. See the systemd module's " +
		"description for full parameter and cross-tool details."
}
