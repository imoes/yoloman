package modules

import (
	"context"
	"fmt"
	"os"
)

// Tempfile creates a temporary file or directory and reports its path,
// mirroring ansible.builtin.tempfile. Unlike most modules here, it is not
// idempotent by nature — like `mktemp`, every real call creates a fresh,
// uniquely named path and always reports changed=true.
type Tempfile struct{}

// NewTempfile returns a Tempfile module.
func NewTempfile() *Tempfile { return &Tempfile{} }

func (t *Tempfile) Name() string { return "tempfile" }

func (t *Tempfile) Description() string {
	return "" +
		"Create a temporary file or directory with a unique name and return its path — for " +
		"staging a scratch location before a later step (e.g. download or render something " +
		"there, then move/copy it into place). Not idempotent by nature (like `mktemp`, every " +
		"real call creates a brand-new uniquely named path and reports changed=true); under " +
		"check_mode (dry_run=true) nothing is created and a predicted path is returned instead.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.tempfile. Same state/path/prefix/suffix semantics.\n" +
		"- Chef: the `directory`/`file` resources combined with Ruby's `Dir.mktmpdir`/`Tempfile` " +
		"in a custom resource — no single built-in resource.\n" +
		"- Puppet: no core equivalent; typically an `exec` wrapping `mktemp`.\n" +
		"- Salt: the `temp.dir`/`temp.file` execution module functions.\n" +
		"- Terraform: not applicable — Terraform manages declared infrastructure, not ephemeral " +
		"scratch paths created during a run."
}

func (t *Tempfile) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"state":   stringEnumProp(`Whether to create a "file" or a "directory". Default "file".`, "file", "directory"),
		"path":    stringProp("Directory under which to create the temp path. Default: the system temp directory."),
		"prefix":  stringProp(`Filename prefix. Default "tmp".`),
		"suffix":  stringProp(`Filename suffix. Default "" (none).`),
		"dry_run": boolProp("When true, do not create anything; return a predicted path (check_mode).", false),
	})
}

func (t *Tempfile) Writes() bool { return true }

func (t *Tempfile) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	state, err := stringParam(params, "state", false, "file")
	if err != nil {
		return Result{}, err
	}
	dir, err := stringParam(params, "path", false, "")
	if err != nil {
		return Result{}, err
	}
	prefix, err := stringParam(params, "prefix", false, "tmp")
	if err != nil {
		return Result{}, err
	}
	suffix, err := stringParam(params, "suffix", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if state != "file" && state != "directory" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want file|directory)", state)
	}
	if dir == "" {
		dir = os.TempDir()
	}
	pattern := prefix + "*" + suffix

	if dryRun {
		return Result{Changed: true, Msg: "would create " + state + " (dry run)", Data: map[string]any{
			"path": dir + "/" + prefix + "XXXXXX" + suffix,
		}}, nil
	}

	var path string
	if state == "directory" {
		path, err = os.MkdirTemp(dir, pattern)
		if err != nil {
			return Result{}, fmt.Errorf("tempfile: creating directory: %w", err)
		}
	} else {
		f, err := os.CreateTemp(dir, pattern)
		if err != nil {
			return Result{}, fmt.Errorf("tempfile: creating file: %w", err)
		}
		path = f.Name()
		if err := f.Close(); err != nil {
			return Result{}, fmt.Errorf("tempfile: closing %q: %w", path, err)
		}
	}

	return Result{Changed: true, Msg: state + " created", Data: map[string]any{"path": path}}, nil
}
