package modules

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Group ensures a system group's existence/gid, mirroring
// ansible.builtin.group. It is idempotent: it checks the current state via
// getent before deciding whether groupadd/groupmod/groupdel is needed.
type Group struct {
	Runner CommandRunner
}

// NewGroup returns a Group module backed by the real getent/groupadd/
// groupmod/groupdel binaries.
func NewGroup() *Group { return &Group{Runner: defaultCommandRunner} }

func (g *Group) Name() string { return "group" }

func (g *Group) Description() string {
	return "" +
		"Ensure a system group exists (optionally with a specific gid) or is absent. " +
		"Idempotent — checks the group's current state via getent first and only calls " +
		"groupadd/groupmod/groupdel when something actually needs to change. Supports " +
		"check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.group. Same name/gid/state/system parameter names (a " +
		"focused subset — Ansible also supports non_unique/local, not yet implemented here).\n" +
		"- Chef: the `group` resource.\n" +
		"- Puppet: the `group` type.\n" +
		"- Salt: the `group.present`/`group.absent` states.\n" +
		"- Terraform: not applicable — Terraform does not manage OS-level accounts on a " +
		"running host."
}

func (g *Group) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Group name, e.g. "deploy".`),
		"gid":     stringProp("Optional specific numeric gid to assign/enforce."),
		"state":   stringEnumProp(`Whether the group should be present or absent. Default "present".`, "present", "absent"),
		"system":  boolProp("For state=present when creating a new group: create it as a system group. Default false.", false),
		"dry_run": boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (g *Group) Writes() bool { return true }

func (g *Group) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	gid, err := stringParam(params, "gid", false, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	system, err := boolParam(params, "system", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if state != "present" && state != "absent" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent)", state)
	}

	current, exists, err := g.lookupGroup(ctx, name)
	if err != nil {
		return Result{}, err
	}

	if state == "absent" {
		if !exists {
			return Result{Changed: false, Msg: "group does not exist", Data: map[string]any{"name": name}}, nil
		}
		if !dryRun {
			if _, err := g.Runner(ctx, "groupdel", name); err != nil {
				return Result{}, fmt.Errorf("group: deleting %s: %w", name, err)
			}
		}
		return Result{Changed: true, Msg: "group removed", Data: map[string]any{"name": name}}, nil
	}

	if !exists {
		args := []string{}
		if gid != "" {
			args = append(args, "-g", gid)
		}
		if system {
			args = append(args, "-r")
		}
		args = append(args, name)
		if !dryRun {
			if _, err := g.Runner(ctx, "groupadd", args...); err != nil {
				return Result{}, fmt.Errorf("group: creating %s: %w", name, err)
			}
		}
		return Result{Changed: true, Msg: "group created", Data: map[string]any{"name": name}}, nil
	}

	if gid != "" && gid != current.gid {
		if !dryRun {
			if _, err := g.Runner(ctx, "groupmod", "-g", gid, name); err != nil {
				return Result{}, fmt.Errorf("group: changing gid of %s: %w", name, err)
			}
		}
		return Result{Changed: true, Msg: "gid updated", Data: map[string]any{"name": name}}, nil
	}

	return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"name": name}}, nil
}

type groupEntry struct {
	gid string
}

// lookupGroup queries getent group <name>, returning (entry, true, nil) if
// found, (zero, false, nil) if not found (getent's own "not found" exit
// code, not a Go error), or (zero, false, err) for any other failure.
func (g *Group) lookupGroup(ctx context.Context, name string) (groupEntry, bool, error) {
	out, err := g.Runner(ctx, "getent", "group", name)
	if err != nil {
		if isGetentNotFound(err) {
			return groupEntry{}, false, nil
		}
		return groupEntry{}, false, fmt.Errorf("group: looking up %s: %w", name, err)
	}
	fields := strings.Split(strings.TrimSpace(string(out)), ":")
	if len(fields) < 3 {
		return groupEntry{}, false, fmt.Errorf("group: unexpected getent output %q", out)
	}
	return groupEntry{gid: fields[2]}, true, nil
}

// isGetentNotFound reports whether err represents getent's "no such entry"
// exit code (2) rather than a genuine failure (e.g. NSS backend down).
// Shared by group.go and user.go.
func isGetentNotFound(err error) bool {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode() == 2
	}
	return false
}
