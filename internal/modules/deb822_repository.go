package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Deb822Repository ensures a modern RFC822-style ("deb822") APT source
// stanza is present or absent in /etc/apt/sources.list.d/<name>.sources,
// mirroring ansible.builtin.deb822_repository. It is idempotent: it only
// writes when the rendered stanza differs from the file's current content.
//
// This implements a focused subset of the real module's many optional
// deb822 fields: types/uris/suites/components/signed_by cover the common
// case; per-field options like Architectures/Languages/trust overrides are
// not implemented here.
type Deb822Repository struct {
	// SourcesDir is where <name>.sources files are read/written. Defaults
	// to /etc/apt/sources.list.d; overridable so tests don't need root.
	SourcesDir string
}

// NewDeb822Repository returns a Deb822Repository module backed by the real
// /etc/apt/sources.list.d.
func NewDeb822Repository() *Deb822Repository {
	return &Deb822Repository{SourcesDir: "/etc/apt/sources.list.d"}
}

func (d *Deb822Repository) Name() string { return "deb822_repository" }

func (d *Deb822Repository) Description() string {
	return "" +
		"Ensure a modern RFC822-style (\"deb822\") APT source stanza is present or absent in " +
		"/etc/apt/sources.list.d/<name>.sources — the format used by apt 2.4+ (Debian 12+, " +
		"Ubuntu 24.04+) in place of the older one-line \"deb ...\" syntax that apt_repository " +
		"manages. Idempotent — only writes when the rendered stanza differs from the file's " +
		"current content. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.deb822_repository. Covers the common types/uris/suites/" +
		"components/signed_by fields (a focused subset — Ansible's real module also supports " +
		"per-field options like Architectures/Languages/trust overrides, not implemented here).\n" +
		"- Chef: the `apt_repository` resource with deb822-style options on newer releases, or " +
		"a hand-written `file` resource for the stanza.\n" +
		"- Puppet: no core equivalent yet at this format's release cadence; typically a `file` " +
		"resource with templated content.\n" +
		"- Salt: the `pkgrepo.managed` state's `key_url`/`aptkey`-adjacent deb822 support, or a " +
		"templated `file.managed`.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's package " +
		"manager configuration."
}

func (d *Deb822Repository) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":       stringProp(`Target file name (without .sources) under /etc/apt/sources.list.d/, e.g. "myrepo".`),
		"types":      stringArrayProp(`Entry types. Default ["deb"].`),
		"uris":       stringArrayProp("Repository URIs. Required for state=present."),
		"suites":     stringArrayProp("Suite names (e.g. distribution codenames). Required for state=present."),
		"components": stringArrayProp("Components (e.g. main, contrib). Optional."),
		"signed_by":  stringProp("Optional path to the repository's signing key."),
		"state":      stringEnumProp(`Whether the entry should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":    boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (d *Deb822Repository) Writes() bool { return true }

func (d *Deb822Repository) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	types, err := stringSliceParam(params, "types", false)
	if err != nil {
		return Result{}, err
	}
	uris, err := stringSliceParam(params, "uris", false)
	if err != nil {
		return Result{}, err
	}
	suites, err := stringSliceParam(params, "suites", false)
	if err != nil {
		return Result{}, err
	}
	components, err := stringSliceParam(params, "components", false)
	if err != nil {
		return Result{}, err
	}
	signedBy, err := stringParam(params, "signed_by", false, "")
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
	if strings.ContainsAny(name, "/\\") {
		return Result{}, fmt.Errorf("name: must not contain path separators")
	}
	path := filepath.Join(d.SourcesDir, name+".sources")

	if state == "absent" {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return Result{Changed: false, Msg: "already absent", Data: map[string]any{"name": name}}, nil
		}
		if !dryRun {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return Result{}, fmt.Errorf("deb822_repository: removing %q: %w", path, err)
			}
		}
		return Result{Changed: true, Msg: "removed", Data: map[string]any{"name": name}}, nil
	}

	if len(uris) == 0 {
		return Result{}, fmt.Errorf("uris: required when state=present")
	}
	if len(suites) == 0 {
		return Result{}, fmt.Errorf("suites: required when state=present")
	}
	if len(types) == 0 {
		types = []string{"deb"}
	}

	desired := renderDeb822Stanza(types, uris, suites, components, signedBy)

	current, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("deb822_repository: reading %q: %w", path, readErr)
	}
	if string(current) == desired {
		return Result{Changed: false, Msg: "already up to date", Data: map[string]any{"name": name}}, nil
	}

	if !dryRun {
		if err := os.MkdirAll(d.SourcesDir, 0o755); err != nil {
			return Result{}, fmt.Errorf("deb822_repository: creating %q: %w", d.SourcesDir, err)
		}
		if err := os.WriteFile(path, []byte(desired), 0o644); err != nil {
			return Result{}, fmt.Errorf("deb822_repository: writing %q: %w", path, err)
		}
	}
	return Result{Changed: true, Msg: "written", Data: map[string]any{"name": name}}, nil
}

// renderDeb822Stanza builds a single deb822-format source stanza.
func renderDeb822Stanza(types, uris, suites, components []string, signedBy string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Types: %s\n", strings.Join(types, " "))
	fmt.Fprintf(&b, "URIs: %s\n", strings.Join(uris, " "))
	fmt.Fprintf(&b, "Suites: %s\n", strings.Join(suites, " "))
	if len(components) > 0 {
		fmt.Fprintf(&b, "Components: %s\n", strings.Join(components, " "))
	}
	if signedBy != "" {
		fmt.Fprintf(&b, "Signed-By: %s\n", signedBy)
	}
	return b.String()
}
