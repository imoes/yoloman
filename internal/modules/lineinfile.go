package modules

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// LineInFile ensures a particular line is present or absent in a file,
// mirroring ansible.builtin.lineinfile. It is idempotent: it only rewrites
// the file when the line set actually needs to change.
type LineInFile struct{}

// NewLineInFile returns a LineInFile module.
func NewLineInFile() *LineInFile { return &LineInFile{} }

func (l *LineInFile) Name() string { return "lineinfile" }

func (l *LineInFile) Description() string {
	return "" +
		"Ensure a single line is present or absent in a text file, without rewriting the rest " +
		"of the file — the classic 'make sure this one config line is set' operation (e.g. a " +
		"sysctl setting, a single key=value pair, an /etc/hosts entry). If `regexp` is given, " +
		"the first line matching it is replaced (state=present) or every matching line is " +
		"removed (state=absent); without `regexp`, an exact line match is used. Idempotent — a " +
		"repeat call with the same parameters reports changed=false. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.lineinfile. Same path/regexp/line/state/create parameter " +
		"names and matching semantics (a focused subset — Ansible also supports insertafter/" +
		"insertbefore/backrefs, not yet implemented here).\n" +
		"- Chef: no single built-in resource; typically composed from `Chef::Util::FileEdit` in " +
		"a custom resource/library, or the community `line` cookbook's `replace_or_add` " +
		"resource.\n" +
		"- Puppet: the `file_line` type from the puppetlabs-stdlib module.\n" +
		"- Salt: the `file.line` or `file.replace` state.\n" +
		"- Terraform: not applicable — Terraform has no line-level file-editing primitive; the " +
		"closest analogue is templating the whole file with `local_file`/`templatefile()`."
}

func (l *LineInFile) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path":    stringProp(`File to edit, e.g. "/etc/sysctl.conf".`),
		"line":    stringProp("The line's exact desired content (for state=present) or the exact line to remove when no regexp is given (for state=absent)."),
		"regexp":  stringProp("Optional RE2 regular expression. For state=present, matches the line to replace with `line` (appends `line` if no match). For state=absent, every matching line is removed."),
		"state":   stringEnumProp(`Whether the line should be present or absent. Default "present".`, "present", "absent"),
		"create":  boolProp("For state=present: if the file does not exist, create it instead of failing. Default false.", false),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "path")
}

func (l *LineInFile) Writes() bool { return true }

func (l *LineInFile) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}
	line, err := stringParam(params, "line", false, "")
	if err != nil {
		return Result{}, err
	}
	regexpStr, err := stringParam(params, "regexp", false, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	create, err := boolParam(params, "create", false)
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
	if state == "present" && line == "" {
		return Result{}, fmt.Errorf("line: required when state=present")
	}

	var re *regexp.Regexp
	if regexpStr != "" {
		re, err = regexp.Compile(regexpStr)
		if err != nil {
			return Result{}, fmt.Errorf("regexp: %w", err)
		}
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if state == "absent" {
				return Result{Changed: false, Msg: "file does not exist, nothing to remove", Data: map[string]any{"path": path}}, nil
			}
			if !create {
				return Result{}, fmt.Errorf("lineinfile: %q does not exist and create=false", path)
			}
			raw = nil
		} else {
			return Result{}, err
		}
	}

	var lines []string
	if len(raw) > 0 {
		lines = strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	}

	newLines, changed := applyLineChange(lines, line, re, state)
	if !changed {
		return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"path": path}}, nil
	}

	if !dryRun {
		content := strings.Join(newLines, "\n") + "\n"
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return Result{}, fmt.Errorf("lineinfile: writing %q: %w", path, err)
		}
	}

	return Result{Changed: true, Msg: "line " + state, Data: map[string]any{"path": path}}, nil
}

// applyLineChange computes the new line set and whether it differs from
// lines, for either state=present (replace-matching-or-append, or exact-
// match-or-append when re is nil) or state=absent (remove matching, or
// remove-exact-match when re is nil).
func applyLineChange(lines []string, line string, re *regexp.Regexp, state string) ([]string, bool) {
	matches := func(l string) bool {
		if re != nil {
			return re.MatchString(l)
		}
		return l == line
	}

	if state == "absent" {
		var out []string
		removed := false
		for _, l := range lines {
			if matches(l) {
				removed = true
				continue
			}
			out = append(out, l)
		}
		return out, removed
	}

	// state == "present"
	for i, l := range lines {
		if matches(l) {
			if l == line {
				return lines, false
			}
			out := append([]string{}, lines...)
			out[i] = line
			return out, true
		}
	}
	return append(append([]string{}, lines...), line), true
}
