package modules

import (
	"bytes"
	"context"
	"fmt"
	"os"
)

// Copy writes literal content or a local file's content to a destination
// path, mirroring ansible.builtin.copy. It is idempotent: it only writes
// when the destination's current content differs from the desired content.
type Copy struct{}

// NewCopy returns a Copy module.
func NewCopy() *Copy { return &Copy{} }

func (c *Copy) Name() string { return "copy" }

func (c *Copy) Description() string {
	return "" +
		"Ensure a destination file's content, owner, group, and mode match a desired value. " +
		"Provide exactly one content source: `content` (a literal string, e.g. a rendered " +
		"config file or a message-of-the-day banner) or `src` (a path to an existing file on " +
		"this same host to copy from). Idempotent — compares the destination's current bytes " +
		"against the desired content and only writes when they differ; reports changed=false " +
		"on a repeat call with the same content. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.copy. Same dest/content/src/owner/group/mode semantics (a " +
		"subset — Ansible's copy also supports remote_src, backup, validate, which are not yet " +
		"implemented here).\n" +
		"- Chef: the `file` resource with a `content` property (for literal content) or the " +
		"`cookbook_file`/`remote_file` resources (for copying a source file).\n" +
		"- Puppet: the `file` type with `content => ...` (literal) or `source => ...` (copy from " +
		"a module file).\n" +
		"- Salt: the `file.managed` state, using its `contents` parameter (literal) or `source` " +
		"parameter (copy from a file).\n" +
		"- Terraform: the `local_file` resource (for files local to the machine running " +
		"Terraform) or a provisioner's `file` block for copying to a remote managed host."
}

func (c *Copy) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"dest":    stringProp(`Destination path to write, e.g. "/etc/motd" or "/etc/nginx/conf.d/app.conf".`),
		"content": stringProp("Literal content to write to dest. Mutually exclusive with src."),
		"src":     stringProp("Path to an existing local file whose content should be copied to dest. Mutually exclusive with content."),
		"owner":   stringProp("Optional desired owner (username or numeric uid)."),
		"group":   stringProp("Optional desired group (group name or numeric gid)."),
		"mode":    stringProp(`Optional desired permission mode as an octal string, e.g. "0644".`),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "dest")
}

func (c *Copy) Writes() bool { return true }

func (c *Copy) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	content, err := stringParam(params, "content", false, "")
	if err != nil {
		return Result{}, err
	}
	src, err := stringParam(params, "src", false, "")
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
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	_, hasContent := params["content"]
	_, hasSrc := params["src"]
	if hasContent == hasSrc {
		return Result{}, fmt.Errorf("copy: exactly one of content or src must be given")
	}

	var desired []byte
	if hasContent {
		desired = []byte(content)
	} else {
		desired, err = os.ReadFile(src)
		if err != nil {
			return Result{}, fmt.Errorf("copy: reading src %q: %w", src, err)
		}
	}

	current, readErr := os.ReadFile(dest)
	contentChanged := readErr != nil || !bytes.Equal(current, desired)

	if contentChanged && !dryRun {
		if err := os.WriteFile(dest, desired, 0o644); err != nil {
			return Result{}, fmt.Errorf("copy: writing %q: %w", dest, err)
		}
	}

	changed := contentChanged
	if !dryRun || !contentChanged {
		// Attribute checks need a real file on disk; if content changed
		// under dry_run, dest may not exist yet for real, so skip them.
		if _, err := os.Lstat(dest); err == nil {
			attrChanged, err := applyOwnerGroupMode(dest, owner, group, mode, dryRun)
			if err != nil {
				return Result{}, err
			}
			changed = changed || attrChanged
		}
	}

	msg := "content already up to date"
	if changed {
		msg = "content or attributes updated"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest}}, nil
}
