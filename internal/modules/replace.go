package modules

import (
	"context"
	"fmt"
	"os"
	"regexp"
)

// Replace performs a regular-expression find-and-replace across an entire
// file's content, mirroring ansible.builtin.replace. It is idempotent: it
// only rewrites the file when the substitution actually changes anything.
type Replace struct{}

// NewReplace returns a Replace module.
func NewReplace() *Replace { return &Replace{} }

func (r *Replace) Name() string { return "replace" }

func (r *Replace) Description() string {
	return "" +
		"Replace every match of a regular expression anywhere in a file's content — unlike " +
		"lineinfile (which matches whole lines), this can match and replace within or across " +
		"lines, and supports Go RE2 backreferences like $1 in the replacement text. Idempotent " +
		"— a repeat call with the same pattern reports changed=false once no more matches exist " +
		"or all matches already read as the replacement. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.replace. Same path/regexp/replace semantics (a focused " +
		"subset — Ansible also supports before/after/backup, not yet implemented here; and " +
		"Ansible's replace uses Python re syntax with \\1 backreferences, this uses Go RE2 " +
		"syntax with $1).\n" +
		"- Chef: no single built-in resource; typically Ruby's own String#gsub inside a " +
		"custom resource/library reading and rewriting the file.\n" +
		"- Puppet: the puppetlabs-stdlib module's `file_line` with `match`/replace-style usage, " +
		"or the third-party augeasproviders modules for structured config formats.\n" +
		"- Salt: the `file.replace` state — nearly identical regex-across-file-content model.\n" +
		"- Terraform: not applicable — no regex file-editing primitive."
}

func (r *Replace) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path":    stringProp(`File to edit, e.g. "/etc/hosts".`),
		"regexp":  stringProp("RE2 regular expression to match anywhere in the file's content."),
		"replace": stringProp(`Replacement text; may reference capture groups as $1, $2, etc. Default "" (delete matches).`),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "path", "regexp")
}

func (r *Replace) Writes() bool { return true }

func (r *Replace) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}
	regexpStr, err := stringParam(params, "regexp", true, "")
	if err != nil {
		return Result{}, err
	}
	replaceWith, err := stringParam(params, "replace", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	re, err := regexp.Compile(regexpStr)
	if err != nil {
		return Result{}, fmt.Errorf("regexp: %w", err)
	}

	original, err := os.ReadFile(path)
	if err != nil {
		return Result{}, fmt.Errorf("replace: reading %q: %w", path, err)
	}

	updated := re.ReplaceAll(original, []byte(replaceWith))
	if string(updated) == string(original) {
		return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"path": path}}, nil
	}

	if !dryRun {
		if err := os.WriteFile(path, updated, 0o644); err != nil {
			return Result{}, fmt.Errorf("replace: writing %q: %w", path, err)
		}
	}

	return Result{Changed: true, Msg: "content replaced", Data: map[string]any{"path": path}}, nil
}
