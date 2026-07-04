package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// YumRepository ensures a yum/dnf .repo file (INI-style, one `[id]`
// section) is present or absent in /etc/yum.repos.d/, mirroring
// ansible.builtin.yum_repository. It is idempotent: it only writes when
// the rendered stanza differs from the file's current content.
//
// Unit-tested only in this project — no RPM-based host in the real
// verification environment (see rpm_pkg.go).
type YumRepository struct {
	// ReposDir is where <file>.repo files are read/written. Defaults to
	// /etc/yum.repos.d; overridable so tests don't need root.
	ReposDir string
}

// NewYumRepository returns a YumRepository module backed by the real
// /etc/yum.repos.d.
func NewYumRepository() *YumRepository { return &YumRepository{ReposDir: "/etc/yum.repos.d"} }

func (y *YumRepository) Name() string { return "yum_repository" }

func (y *YumRepository) Description() string {
	return "" +
		"Ensure a yum/dnf repository definition (an INI-style [id] section) is present or " +
		"absent in /etc/yum.repos.d/<file>.repo. Idempotent — only writes when the rendered " +
		"stanza differs from the file's current content. Supports check_mode via dry_run=true. " +
		"Unit-tested only in this project — no RPM-based host in the real verification " +
		"environment (contrast with apt_repository, which is real-tested on Debian).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.yum_repository. Covers the common name/description/baseurl/" +
		"enabled/gpgcheck/gpgkey/file/state fields (a focused subset — Ansible's own module " +
		"supports many more optional .repo keys, not implemented here).\n" +
		"- Chef: the `yum_repository` resource.\n" +
		"- Puppet: the `yumrepo` type.\n" +
		"- Salt: the `pkgrepo.managed`/`pkgrepo.absent` states.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's package " +
		"manager configuration."
}

func (y *YumRepository) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":        stringProp(`Repository id — the INI section header, e.g. "myrepo".`),
		"description": stringProp("Human-readable repo name (the .repo file's name= field)."),
		"baseurl":     stringProp("Repository base URL. Required for state=present."),
		"enabled":     boolProp("Whether the repository is enabled. Default true.", true),
		"gpgcheck":    boolProp("Whether to verify package signatures. Default true.", true),
		"gpgkey":      stringProp("Optional URL to the repository's GPG key."),
		"file":        stringProp("Target file name (without .repo) under /etc/yum.repos.d/. Defaults to name."),
		"state":       stringEnumProp(`Whether the repository should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":     boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (y *YumRepository) Writes() bool { return true }

func (y *YumRepository) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	description, err := stringParam(params, "description", false, "")
	if err != nil {
		return Result{}, err
	}
	baseurl, err := stringParam(params, "baseurl", false, "")
	if err != nil {
		return Result{}, err
	}
	enabled, err := boolParam(params, "enabled", true)
	if err != nil {
		return Result{}, err
	}
	gpgcheck, err := boolParam(params, "gpgcheck", true)
	if err != nil {
		return Result{}, err
	}
	gpgkey, err := stringParam(params, "gpgkey", false, "")
	if err != nil {
		return Result{}, err
	}
	file, err := stringParam(params, "file", false, "")
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
	if file == "" {
		file = name
	}
	if strings.ContainsAny(file, "/\\") {
		return Result{}, fmt.Errorf("file: must not contain path separators")
	}
	path := filepath.Join(y.ReposDir, file+".repo")

	if state == "absent" {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return Result{Changed: false, Msg: "already absent", Data: map[string]any{"name": name}}, nil
		}
		if !dryRun {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return Result{}, fmt.Errorf("yum_repository: removing %q: %w", path, err)
			}
		}
		return Result{Changed: true, Msg: "removed", Data: map[string]any{"name": name}}, nil
	}

	if baseurl == "" {
		return Result{}, fmt.Errorf("baseurl: required when state=present")
	}

	desired := renderYumRepoStanza(name, description, baseurl, enabled, gpgcheck, gpgkey)

	current, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("yum_repository: reading %q: %w", path, readErr)
	}
	if string(current) == desired {
		return Result{Changed: false, Msg: "already up to date", Data: map[string]any{"name": name}}, nil
	}

	if !dryRun {
		if err := os.MkdirAll(y.ReposDir, 0o755); err != nil {
			return Result{}, fmt.Errorf("yum_repository: creating %q: %w", y.ReposDir, err)
		}
		if err := os.WriteFile(path, []byte(desired), 0o644); err != nil {
			return Result{}, fmt.Errorf("yum_repository: writing %q: %w", path, err)
		}
	}
	return Result{Changed: true, Msg: "written", Data: map[string]any{"name": name}}, nil
}

// renderYumRepoStanza builds a single INI-style .repo section.
func renderYumRepoStanza(name, description, baseurl string, enabled, gpgcheck bool, gpgkey string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[%s]\n", name)
	if description != "" {
		fmt.Fprintf(&b, "name=%s\n", description)
	}
	fmt.Fprintf(&b, "baseurl=%s\n", baseurl)
	fmt.Fprintf(&b, "enabled=%s\n", boolToRepoFlag(enabled))
	fmt.Fprintf(&b, "gpgcheck=%s\n", boolToRepoFlag(gpgcheck))
	if gpgkey != "" {
		fmt.Fprintf(&b, "gpgkey=%s\n", gpgkey)
	}
	return b.String()
}

func boolToRepoFlag(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
