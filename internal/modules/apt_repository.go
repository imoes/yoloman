package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AptRepository ensures a one-line APT source entry is present or absent
// in a specific file under /etc/apt/sources.list.d/, mirroring
// ansible.builtin.apt_repository. It is idempotent: it checks whether the
// exact line already exists before writing.
//
// This implements a focused subset of the real module: `filename` is
// required here (Ansible derives a default name from the repo string via
// its own heuristic; requiring it keeps this module's behavior simple and
// predictable), and state=absent only removes the entry from that specific
// file rather than searching every configured source file.
type AptRepository struct {
	Runner CommandRunner
	// SourcesDir is where <filename>.list files are read/written. Defaults
	// to /etc/apt/sources.list.d; overridable so tests don't need root or
	// to touch the real system.
	SourcesDir string
}

// NewAptRepository returns an AptRepository module backed by the real
// apt-get binary (for optional cache updates) and /etc/apt/sources.list.d.
func NewAptRepository() *AptRepository {
	return &AptRepository{Runner: defaultCommandRunner, SourcesDir: "/etc/apt/sources.list.d"}
}

func (a *AptRepository) Name() string { return "apt_repository" }

func (a *AptRepository) Description() string {
	return "" +
		"Ensure a one-line APT source entry (e.g. \"deb https://example.com/repo stable main\") " +
		"is present or absent in /etc/apt/sources.list.d/<filename>.list. Idempotent — only " +
		"writes when the exact line isn't already there (state=present) or is there " +
		"(state=absent). Optionally runs `apt-get update` afterward when update_cache=true and " +
		"something changed. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.apt_repository. Similar repo/state/update_cache semantics — " +
		"a focused subset: `filename` is required here rather than auto-derived, and " +
		"state=absent only searches the given file rather than every configured source file.\n" +
		"- Chef: the `apt_repository` resource (part of the apt cookbook).\n" +
		"- Puppet: the puppetlabs-apt module's `apt::source` type.\n" +
		"- Salt: the `pkgrepo.managed`/`pkgrepo.absent` states.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's package " +
		"manager configuration."
}

func (a *AptRepository) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"repo":         stringProp(`The full one-line source entry, e.g. "deb https://example.com/repo stable main". Required for state=present.`),
		"filename":     stringProp(`Target file name (without .list) under /etc/apt/sources.list.d/, e.g. "myrepo".`),
		"state":        stringEnumProp(`Whether the entry should be present or absent. Default "present".`, "present", "absent"),
		"update_cache": boolProp("When true and something changed, run apt-get update afterward. Default false.", false),
		"dry_run":      boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "filename")
}

func (a *AptRepository) Writes() bool { return true }

func (a *AptRepository) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	repo, err := stringParam(params, "repo", false, "")
	if err != nil {
		return Result{}, err
	}
	filename, err := stringParam(params, "filename", true, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	updateCache, err := boolParam(params, "update_cache", false)
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
	if state == "present" && repo == "" {
		return Result{}, fmt.Errorf("repo: required when state=present")
	}
	if strings.ContainsAny(filename, "/\\") {
		return Result{}, fmt.Errorf("filename: must not contain path separators")
	}

	path := filepath.Join(a.SourcesDir, filename+".list")

	raw, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("apt_repository: reading %q: %w", path, readErr)
	}
	var lines []string
	if len(raw) > 0 {
		lines = strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	}

	present := false
	idx := -1
	for i, l := range lines {
		if l == repo {
			present = true
			idx = i
			break
		}
	}

	var changed bool
	var newLines []string
	if state == "present" {
		if present {
			return Result{Changed: false, Msg: "repository already present", Data: map[string]any{"filename": filename}}, nil
		}
		newLines = append(append([]string{}, lines...), repo)
		changed = true
	} else {
		if !present {
			return Result{Changed: false, Msg: "repository already absent", Data: map[string]any{"filename": filename}}, nil
		}
		newLines = append(append([]string{}, lines[:idx]...), lines[idx+1:]...)
		changed = true
	}

	if changed && !dryRun {
		if len(newLines) == 0 {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return Result{}, fmt.Errorf("apt_repository: removing empty %q: %w", path, err)
			}
		} else {
			if err := os.MkdirAll(a.SourcesDir, 0o755); err != nil {
				return Result{}, fmt.Errorf("apt_repository: creating %q: %w", a.SourcesDir, err)
			}
			content := strings.Join(newLines, "\n") + "\n"
			if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
				return Result{}, fmt.Errorf("apt_repository: writing %q: %w", path, err)
			}
		}
		if updateCache {
			if _, err := a.Runner(ctx, "apt-get", "update"); err != nil {
				return Result{}, fmt.Errorf("apt_repository: updating apt cache: %w", err)
			}
		}
	}

	return Result{Changed: true, Msg: "repository " + state, Data: map[string]any{"filename": filename}}, nil
}
