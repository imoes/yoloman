package modules

import (
	"context"
	"fmt"
	"os"
	"time"
)

// File manages a path's existence, type, and ownership/mode, mirroring
// ansible.builtin.file. It is idempotent: it inspects the current state
// first and only changes what differs from the desired state.
type File struct{}

// NewFile returns a File module.
func NewFile() *File { return &File{} }

func (f *File) Name() string { return "file" }

func (f *File) Description() string {
	return "" +
		"Set the state of a path: ensure a directory exists, ensure a path is absent (file or " +
		"directory, removed recursively), touch an empty file into existence, or assert " +
		"attributes (owner/group/mode) on an existing file/directory. Idempotent — running it " +
		"twice with the same parameters produces changed=false the second time. Supports " +
		"check_mode: pass dry_run=true to preview whether anything would change without " +
		"touching the filesystem.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.file. Same path/state/owner/group/mode parameter names; " +
		"supports state=file|directory|absent|touch|link (state=link requires 'src', the link " +
		"target; Ansible additionally supports state=hard for hardlinks, not yet implemented " +
		"here).\n" +
		"- Chef: the `directory` resource (state=directory), `file` resource with action :delete " +
		"(state=absent) or action :create_if_missing / :touch (state=touch), and a `file` " +
		"resource's owner/group/mode properties for attribute assertions.\n" +
		"- Puppet: the `file` type — `ensure => directory`, `ensure => absent`, `ensure => " +
		"present` (touch-like), with `owner`/`group`/`mode` parameters.\n" +
		"- Salt: the `file.directory` state (state=directory), `file.absent` (state=absent), " +
		"`file.touch` (state=touch), or `file.managed`'s user/group/mode for attribute-only " +
		"changes.\n" +
		"- Terraform: not a natural fit — Terraform manages infrastructure resources, not " +
		"arbitrary remote-file attributes; the closest analogue is a provisioner " +
		"(`remote-exec`/`local-exec`) invoking mkdir/rm/touch/chown/chmod, which loses " +
		"Terraform's own state tracking for that action."
}

func (f *File) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path":    stringProp(`Path to manage, e.g. "/opt/app/data" or "/etc/myapp/config.d".`),
		"state":   stringEnumProp(`Desired state. Default "file" (assert attributes on an existing file, error if missing).`, "file", "directory", "absent", "touch", "link"),
		"src":     stringProp(`The symlink target. Required when state=link, e.g. "/data1/var_lib_docker" for path "/var/lib/docker".`),
		"owner":   stringProp("Optional desired owner (username or numeric uid). Leave unset to not manage ownership."),
		"group":   stringProp("Optional desired group (group name or numeric gid). Leave unset to not manage group."),
		"mode":    stringProp(`Optional desired permission mode as an octal string, e.g. "0644" or "755". Leave unset to not manage mode. Ignored when state=link — symlink permission bits are not meaningfully manageable on Linux.`),
		"dry_run": boolProp("When true, report what would change without modifying the filesystem (check_mode).", false),
	}, "path")
}

func (f *File) Writes() bool { return true }

func (f *File) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "file")
	if err != nil {
		return Result{}, err
	}
	owner, err := stringParam(params, "owner", false, "")
	if err != nil {
		return Result{}, err
	}
	group, err := stringParam(params, "group", false, "")
	if err != nil {
		return Result{}, err
	}
	mode, err := stringParam(params, "mode", false, "")
	if err != nil {
		return Result{}, err
	}
	src, err := stringParam(params, "src", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	switch state {
	case "directory":
		return f.runDirectory(path, owner, group, mode, dryRun)
	case "absent":
		return f.runAbsent(path, dryRun)
	case "touch":
		return f.runTouch(path, owner, group, mode, dryRun)
	case "file":
		return f.runFile(path, owner, group, mode, dryRun)
	case "link":
		return f.runLink(path, src, owner, group, dryRun)
	default:
		return Result{}, fmt.Errorf("state: unsupported value %q (want file|directory|absent|touch|link)", state)
	}
}

func (f *File) runDirectory(path, owner, group, mode string, dryRun bool) (Result, error) {
	fi, err := os.Stat(path)
	existedAsDir := err == nil && fi.IsDir()
	if err == nil && !fi.IsDir() {
		return Result{}, fmt.Errorf("file: %q exists and is not a directory", path)
	}
	if err != nil && !os.IsNotExist(err) {
		return Result{}, err
	}

	changed := !existedAsDir
	if changed && !dryRun {
		if err := os.MkdirAll(path, 0o755); err != nil {
			return Result{}, fmt.Errorf("file: creating directory %q: %w", path, err)
		}
	}

	// Only check owner/group/mode against a path that actually exists on
	// disk: either it pre-existed, or dryRun is false and we just created
	// it for real. Under dry_run against a not-yet-real directory there is
	// nothing on disk to inspect attributes of.
	if existedAsDir || !dryRun {
		attrChanged, err := applyOwnerGroupMode(path, owner, group, mode, dryRun)
		if err != nil {
			return Result{}, err
		}
		changed = changed || attrChanged
	}

	msg := "directory already present"
	if changed {
		msg = "directory created or attributes updated"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"path": path, "state": "directory"}}, nil
}

func (f *File) runAbsent(path string, dryRun bool) (Result, error) {
	_, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return Result{Changed: false, Msg: "already absent", Data: map[string]any{"path": path, "state": "absent"}}, nil
	}
	if err != nil {
		return Result{}, err
	}
	if !dryRun {
		if err := os.RemoveAll(path); err != nil {
			return Result{}, fmt.Errorf("file: removing %q: %w", path, err)
		}
	}
	return Result{Changed: true, Msg: "removed", Data: map[string]any{"path": path, "state": "absent"}}, nil
}

func (f *File) runTouch(path, owner, group, mode string, dryRun bool) (Result, error) {
	_, err := os.Lstat(path)
	changed := false
	if os.IsNotExist(err) {
		changed = true
		if !dryRun {
			file, ferr := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o644)
			if ferr != nil {
				return Result{}, fmt.Errorf("file: touching %q: %w", path, ferr)
			}
			file.Close()
		}
	} else if err != nil {
		return Result{}, err
	}

	if !dryRun {
		attrChanged, err := applyOwnerGroupMode(path, owner, group, mode, dryRun)
		if err != nil {
			return Result{}, err
		}
		changed = changed || attrChanged
	}

	return Result{Changed: changed, Msg: "touched", Data: map[string]any{"path": path, "state": "touch", "checked_at": time.Now().Unix()}}, nil
}

func (f *File) runLink(path, src, owner, group string, dryRun bool) (Result, error) {
	if src == "" {
		return Result{}, fmt.Errorf("file: state=link requires 'src' (the link target)")
	}

	fi, err := os.Lstat(path)
	switch {
	case err == nil && fi.Mode()&os.ModeSymlink != 0:
		currentTarget, rerr := os.Readlink(path)
		if rerr != nil {
			return Result{}, fmt.Errorf("file: reading existing symlink %q: %w", path, rerr)
		}
		if currentTarget != src {
			if !dryRun {
				if rerr := os.Remove(path); rerr != nil {
					return Result{}, fmt.Errorf("file: removing stale symlink %q: %w", path, rerr)
				}
				if rerr := os.Symlink(src, path); rerr != nil {
					return Result{}, fmt.Errorf("file: creating symlink %q -> %q: %w", path, src, rerr)
				}
			}
			return f.finishLink(path, src, owner, group, true, dryRun)
		}
	case err == nil:
		return Result{}, fmt.Errorf("file: %q exists and is not a symlink", path)
	case os.IsNotExist(err):
		if !dryRun {
			if serr := os.Symlink(src, path); serr != nil {
				return Result{}, fmt.Errorf("file: creating symlink %q -> %q: %w", path, src, serr)
			}
		}
		return f.finishLink(path, src, owner, group, true, dryRun)
	default:
		return Result{}, err
	}

	return f.finishLink(path, src, owner, group, false, dryRun)
}

// finishLink applies owner/group to an already-correct symlink (via
// lchown, which acts on the link itself rather than following it — using
// the regular chown-based applyOwnerGroupMode here would silently retarget
// every subsequent run's ownership check at src instead of path, making
// state=link never converge to changed=false) and folds in the
// create/retarget outcome already known by the caller.
func (f *File) finishLink(path, src, owner, group string, alreadyChanged, dryRun bool) (Result, error) {
	changed := alreadyChanged
	if (!dryRun || !alreadyChanged) && (owner != "" || group != "") {
		attrChanged, err := applyOwnerGroupOnLink(path, owner, group, dryRun)
		if err != nil {
			return Result{}, err
		}
		changed = changed || attrChanged
	}
	return Result{Changed: changed, Msg: "symlink present", Data: map[string]any{"path": path, "src": src, "state": "link"}}, nil
}

func (f *File) runFile(path, owner, group, mode string, dryRun bool) (Result, error) {
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return Result{}, fmt.Errorf("file: %q does not exist (state=file only asserts attributes on an existing path; use state=touch or state=directory to create it)", path)
		}
		return Result{}, err
	}
	changed, err := applyOwnerGroupMode(path, owner, group, mode, dryRun)
	if err != nil {
		return Result{}, err
	}
	return Result{Changed: changed, Msg: "attributes verified", Data: map[string]any{"path": path, "state": "file"}}, nil
}
