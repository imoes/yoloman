package modules

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

// User ensures a system user account's existence/attributes, mirroring
// ansible.builtin.user. It is idempotent: it checks the current state via
// getent/id before deciding whether useradd/usermod/userdel is needed.
//
// Password/credential management (Ansible's password/password_lock/ssh_key_*
// options) is deliberately out of scope — setting a pre-hashed password via
// this module would make it too easy to leak a hash through a tool-call log
// or audit trail; use a dedicated secrets-aware mechanism for that instead.
type User struct {
	Runner CommandRunner
}

// NewUser returns a User module backed by the real getent/id/useradd/
// usermod/userdel binaries.
func NewUser() *User { return &User{Runner: defaultCommandRunner} }

func (u *User) Name() string { return "user" }

func (u *User) Description() string {
	return "" +
		"Ensure a system user account exists (with a given uid/primary group/secondary groups/" +
		"shell/home/comment) or is absent. Idempotent — checks the account's current state via " +
		"getent/id first and only calls useradd/usermod/userdel when something actually needs " +
		"to change. Supports check_mode via dry_run=true. Password/credential management is " +
		"deliberately not supported here — set that through a dedicated secrets-aware path, not " +
		"a tool call that ends up in an audit log.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.user. Same name/uid/group/groups/append/shell/home/" +
		"create_home/comment/system/remove/state parameter names (a focused subset — Ansible " +
		"also supports password/expires/ssh_key_*/non_unique, not implemented here).\n" +
		"- Chef: the `user` resource.\n" +
		"- Puppet: the `user` type.\n" +
		"- Salt: the `user.present`/`user.absent` states.\n" +
		"- Terraform: not applicable — Terraform does not manage OS-level accounts on a " +
		"running host."
}

func (u *User) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":        stringProp(`Username, e.g. "deploy".`),
		"uid":         stringProp("Optional specific numeric uid to assign/enforce."),
		"group":       stringProp("Optional primary group name or gid."),
		"groups":      stringArrayProp("Optional list of secondary group names."),
		"append":      boolProp("When true, add to existing secondary groups rather than replacing them. Default false.", false),
		"shell":       stringProp(`Optional login shell, e.g. "/bin/bash".`),
		"home":        stringProp("Optional home directory path."),
		"create_home": boolProp("For state=present when creating a new user: also create the home directory. Default true.", true),
		"comment":     stringProp("Optional GECOS/comment field (typically the user's real name)."),
		"system":      boolProp("For state=present when creating a new user: create it as a system account. Default false.", false),
		"remove":      boolProp("For state=absent: also remove the home directory and mail spool. Default false.", false),
		"state":       stringEnumProp(`Whether the account should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":     boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (u *User) Writes() bool { return true }

func (u *User) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	uid, err := stringParam(params, "uid", false, "")
	if err != nil {
		return Result{}, err
	}
	group, err := stringParam(params, "group", false, "")
	if err != nil {
		return Result{}, err
	}
	groups, err := stringSliceParam(params, "groups", false)
	if err != nil {
		return Result{}, err
	}
	append_, err := boolParam(params, "append", false)
	if err != nil {
		return Result{}, err
	}
	shell, err := stringParam(params, "shell", false, "")
	if err != nil {
		return Result{}, err
	}
	home, err := stringParam(params, "home", false, "")
	if err != nil {
		return Result{}, err
	}
	createHome, err := boolParam(params, "create_home", true)
	if err != nil {
		return Result{}, err
	}
	comment, err := stringParam(params, "comment", false, "")
	if err != nil {
		return Result{}, err
	}
	system, err := boolParam(params, "system", false)
	if err != nil {
		return Result{}, err
	}
	remove, err := boolParam(params, "remove", false)
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
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

	current, exists, err := u.lookupUser(ctx, name)
	if err != nil {
		return Result{}, err
	}

	if state == "absent" {
		if !exists {
			return Result{Changed: false, Msg: "user does not exist", Data: map[string]any{"name": name}}, nil
		}
		if !dryRun {
			args := []string{}
			if remove {
				args = append(args, "-r")
			}
			args = append(args, name)
			if _, err := u.Runner(ctx, "userdel", args...); err != nil {
				return Result{}, fmt.Errorf("user: deleting %s: %w", name, err)
			}
		}
		return Result{Changed: true, Msg: "user removed", Data: map[string]any{"name": name}}, nil
	}

	if !exists {
		args := []string{}
		if uid != "" {
			args = append(args, "-u", uid)
		}
		if group != "" {
			args = append(args, "-g", group)
		}
		if len(groups) > 0 {
			args = append(args, "-G", strings.Join(groups, ","))
		}
		if shell != "" {
			args = append(args, "-s", shell)
		}
		if home != "" {
			args = append(args, "-d", home)
		}
		if comment != "" {
			args = append(args, "-c", comment)
		}
		if system {
			args = append(args, "-r")
		}
		if createHome {
			args = append(args, "-m")
		} else {
			args = append(args, "-M")
		}
		args = append(args, name)
		if !dryRun {
			if _, err := u.Runner(ctx, "useradd", args...); err != nil {
				return Result{}, fmt.Errorf("user: creating %s: %w", name, err)
			}
		}
		return Result{Changed: true, Msg: "user created", Data: map[string]any{"name": name}}, nil
	}

	var modArgs []string
	if uid != "" && uid != current.uid {
		modArgs = append(modArgs, "-u", uid)
	}
	if group != "" && group != current.gid {
		modArgs = append(modArgs, "-g", group)
	}
	if shell != "" && shell != current.shell {
		modArgs = append(modArgs, "-s", shell)
	}
	if home != "" && home != current.home {
		modArgs = append(modArgs, "-d", home)
	}
	if comment != "" && comment != current.comment {
		modArgs = append(modArgs, "-c", comment)
	}
	if len(groups) > 0 {
		currentGroups, err := u.secondaryGroups(ctx, name)
		if err != nil {
			return Result{}, err
		}
		if groupsNeedUpdate(currentGroups, groups, append_) {
			flag := "-G"
			if append_ {
				modArgs = append(modArgs, "-a", flag, strings.Join(groups, ","))
			} else {
				modArgs = append(modArgs, flag, strings.Join(groups, ","))
			}
		}
	}

	if len(modArgs) == 0 {
		return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"name": name}}, nil
	}

	if !dryRun {
		modArgs = append(modArgs, name)
		if _, err := u.Runner(ctx, "usermod", modArgs...); err != nil {
			return Result{}, fmt.Errorf("user: updating %s: %w", name, err)
		}
	}
	return Result{Changed: true, Msg: "user updated", Data: map[string]any{"name": name}}, nil
}

type userEntry struct {
	uid, gid, comment, home, shell string
}

// lookupUser queries getent passwd <name>, returning (entry, true, nil) if
// found, (zero, false, nil) if not found, or (zero, false, err) for any
// other failure.
func (u *User) lookupUser(ctx context.Context, name string) (userEntry, bool, error) {
	out, err := u.Runner(ctx, "getent", "passwd", name)
	if err != nil {
		if isGetentNotFound(err) {
			return userEntry{}, false, nil
		}
		return userEntry{}, false, fmt.Errorf("user: looking up %s: %w", name, err)
	}
	// name:passwd:uid:gid:comment:home:shell
	fields := strings.SplitN(strings.TrimSpace(string(out)), ":", 7)
	if len(fields) < 7 {
		return userEntry{}, false, fmt.Errorf("user: unexpected getent output %q", out)
	}
	return userEntry{uid: fields[2], gid: fields[3], comment: fields[4], home: fields[5], shell: fields[6]}, true, nil
}

// secondaryGroups returns name's current secondary group names via `id -Gn`.
func (u *User) secondaryGroups(ctx context.Context, name string) ([]string, error) {
	out, err := u.Runner(ctx, "id", "-Gn", name)
	if err != nil {
		return nil, fmt.Errorf("user: listing groups for %s: %w", name, err)
	}
	return strings.Fields(string(out)), nil
}

// groupsNeedUpdate reports whether usermod -G/-aG is actually needed: for
// append mode, whether any desired group is missing from current; for
// replace mode, whether the sorted sets differ at all.
func groupsNeedUpdate(current, desired []string, append_ bool) bool {
	if append_ {
		currentSet := make(map[string]bool, len(current))
		for _, g := range current {
			currentSet[g] = true
		}
		for _, g := range desired {
			if !currentSet[g] {
				return true
			}
		}
		return false
	}

	a := append([]string{}, current...)
	b := append([]string{}, desired...)
	sort.Strings(a)
	sort.Strings(b)
	if len(a) != len(b) {
		return true
	}
	for i := range a {
		if a[i] != b[i] {
			return true
		}
	}
	return false
}
