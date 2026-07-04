package modules

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

// Assemble concatenates all files in a source directory (optionally
// filtered by a filename regexp, always sorted by name) into a single
// destination file, mirroring ansible.builtin.assemble. It is idempotent:
// it only writes when the assembled content differs from dest's current
// content.
type Assemble struct{}

// NewAssemble returns an Assemble module.
func NewAssemble() *Assemble { return &Assemble{} }

func (a *Assemble) Name() string { return "assemble" }

func (a *Assemble) Description() string {
	return "" +
		"Concatenate every file in a source directory — sorted by filename, optionally filtered " +
		"to names matching a regexp — into a single destination file. The classic use case is a " +
		"conf.d-style fragment directory (e.g. /etc/myapp/conf.d/*.conf) assembled into the " +
		"application's single real config file. Idempotent — only writes dest when the assembled " +
		"content actually differs from what's already there. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.assemble. Same src/dest/regexp/delimiter/owner/group/mode " +
		"semantics (a focused subset — Ansible also supports remote_src=false to assemble from " +
		"the control node, not applicable here since there is no separate control-node " +
		"filesystem in this agent's single-host model; ignore_hidden/validate not yet " +
		"implemented).\n" +
		"- Chef: no single built-in resource; typically hand-rolled by reading a directory glob " +
		"and writing a `file` resource's content in a custom recipe/library.\n" +
		"- Puppet: no core equivalent; the `concat` module (puppetlabs-concat) provides the same " +
		"fragment-directory-to-single-file pattern.\n" +
		"- Salt: no single built-in state; typically composed with Jinja `{% include %}`/glob " +
		"logic inside a `file.managed` template, or a custom module.\n" +
		"- Terraform: not applicable — no file-fragment-assembly primitive."
}

func (a *Assemble) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"src":       stringProp(`Source directory of fragment files, e.g. "/etc/myapp/conf.d".`),
		"dest":      stringProp(`Destination file to write the assembled content to, e.g. "/etc/myapp/myapp.conf".`),
		"regexp":    stringProp("Optional RE2 regular expression; only filenames matching it are included. Default: all files."),
		"delimiter": stringProp("Optional string inserted between fragments. Default: none."),
		"owner":     stringProp("Optional desired owner (username or numeric uid) for dest."),
		"group":     stringProp("Optional desired group (group name or numeric gid) for dest."),
		"mode":      stringProp(`Optional desired permission mode for dest as an octal string, e.g. "0644".`),
		"dry_run":   boolProp("When true, report what would change without writing (check_mode).", false),
	}, "src", "dest")
}

func (a *Assemble) Writes() bool { return true }

func (a *Assemble) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	src, err := stringParam(params, "src", true, "")
	if err != nil {
		return Result{}, err
	}
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	regexpStr, err := stringParam(params, "regexp", false, "")
	if err != nil {
		return Result{}, err
	}
	delimiter, err := stringParam(params, "delimiter", false, "")
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

	var re *regexp.Regexp
	if regexpStr != "" {
		re, err = regexp.Compile(regexpStr)
		if err != nil {
			return Result{}, fmt.Errorf("regexp: %w", err)
		}
	}

	entries, err := os.ReadDir(src)
	if err != nil {
		return Result{}, fmt.Errorf("assemble: reading src %q: %w", src, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if re != nil && !re.MatchString(e.Name()) {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	var buf bytes.Buffer
	for i, name := range names {
		if i > 0 && delimiter != "" {
			buf.WriteString(delimiter)
		}
		content, err := os.ReadFile(filepath.Join(src, name))
		if err != nil {
			return Result{}, fmt.Errorf("assemble: reading fragment %q: %w", name, err)
		}
		buf.Write(content)
	}
	desired := buf.Bytes()

	current, readErr := os.ReadFile(dest)
	contentChanged := readErr != nil || !bytes.Equal(current, desired)

	if contentChanged && !dryRun {
		if err := os.WriteFile(dest, desired, 0o644); err != nil {
			return Result{}, fmt.Errorf("assemble: writing %q: %w", dest, err)
		}
	}

	changed := contentChanged
	if !dryRun || !contentChanged {
		if _, err := os.Lstat(dest); err == nil {
			attrChanged, err := applyOwnerGroupMode(dest, owner, group, mode, dryRun)
			if err != nil {
				return Result{}, err
			}
			changed = changed || attrChanged
		}
	}

	msg := "dest already up to date"
	if changed {
		msg = "dest assembled from src fragments"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest, "fragments": len(names)}}, nil
}
