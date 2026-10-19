package modules

import (
	"context"
	"fmt"
	"strings"
)

// rpmPackageManager implements the shared install/remove/upgrade logic for
// yum, dnf, and dnf5 — RPM-based package manager frontends (RHEL/CentOS/
// Fedora and derivatives) that share the same install/remove/list CLI
// surface for the common case. Yum, Dnf, and Dnf5 each wrap one with a
// different binary name.
//
// The check/apply logic mirrors apt.go's structure (query via the underlying
// rpm database, act via the frontend binary). dnf has run for real on the
// AlmaLinux 9 e2e hosts (docs/package-config-e2e.md); yum and dnf5 are
// unit-tested only.
type rpmPackageManager struct {
	binary string // "yum", "dnf", or "dnf5"
	Runner CommandRunner
}

func (r *rpmPackageManager) inputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringArrayProp(`One or more package names, e.g. ["httpd"] or ["httpd", "curl"].`),
		"state":   stringEnumProp(`Desired package state. Default "present".`, "present", "absent", "latest"),
		"dry_run": boolProp("When true, report what would change without issuing any mutating command (check_mode). For state=latest, an already-installed package conservatively predicts changed=true under dry_run, since determining whether a newer version truly exists would itself require a repository query — see the module description.", false),
	}, "name")
}

func (r *rpmPackageManager) run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	names, err := stringOrStringSliceParam(params, "name", true)
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
	if state != "present" && state != "absent" && state != "latest" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent|latest)", state)
	}

	changed := false
	var results []map[string]any
	for _, pkgName := range names {
		installed, version, err := r.rpmStatus(ctx, pkgName)
		if err != nil {
			return Result{}, fmt.Errorf("%s: querying %s: %w", r.binary, pkgName, err)
		}

		var pkgChanged bool
		var action string
		switch state {
		case "present":
			pkgChanged = !installed
			action = "install"
		case "absent":
			pkgChanged = installed
			action = "remove"
		case "latest":
			if !installed {
				pkgChanged = true
				action = "install"
			} else if dryRun {
				// See inputSchema's dry_run description: a real update
				// check under check_mode would itself require a
				// (possibly slow, network-dependent) repo query; this
				// conservatively predicts a change is possible.
				pkgChanged = true
				action = "update"
			} else {
				action = "update"
				before := version
				if err := r.mutate(ctx, action, pkgName); err != nil {
					return Result{}, fmt.Errorf("%s: updating %s: %w", r.binary, pkgName, err)
				}
				_, after, err := r.rpmStatus(ctx, pkgName)
				if err != nil {
					return Result{}, fmt.Errorf("%s: querying %s after update: %w", r.binary, pkgName, err)
				}
				pkgChanged = after != before
				changed = changed || pkgChanged
				results = append(results, map[string]any{"name": pkgName, "installed_version": after, "changed": pkgChanged})
				continue
			}
		}

		// A preview must fail where the real install would (same rule as apt): ask the repositories whether
		// they offer the package at all, instead of predicting "would install" for a name nobody ships.
		wouldInstall := ""
		if pkgChanged && dryRun && action == "install" {
			v, err := r.availableVersion(ctx, pkgName)
			if err != nil {
				return Result{}, err
			}
			wouldInstall = v
		}

		if pkgChanged && !dryRun {
			if err := r.mutate(ctx, action, pkgName); err != nil {
				return Result{}, fmt.Errorf("%s: %sing %s: %w", r.binary, action, pkgName, err)
			}
		}

		changed = changed || pkgChanged
		entry := map[string]any{"name": pkgName, "installed_version": version, "changed": pkgChanged}
		if wouldInstall != "" {
			entry["would_install_version"] = wouldInstall
		}
		results = append(results, entry)
	}

	return Result{Changed: changed, Msg: "package state applied", Data: results}, nil
}

// availableVersion is the version the repositories offer for pkg (`<binary> -q list --available pkg`), or an error
// naming the package when none does — what the install itself would fail with.
func (r *rpmPackageManager) availableVersion(ctx context.Context, pkg string) (string, error) {
	out, err := r.Runner(ctx, r.binary, "-q", "list", "--available", pkg)
	if err != nil && !isExitError(err) {
		return "", fmt.Errorf("%s: querying the repositories for %s: %w", r.binary, pkg, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && (f[0] == pkg || strings.HasPrefix(f[0], pkg+".")) {
			return f[1], nil
		}
	}
	return "", fmt.Errorf("%s: %s is not offered by any enabled repository (%s list --available); installing it "+
		"would fail with \"No match for argument\"", r.binary, pkg, r.binary)
}

// staleMetadataSigns are what dnf/yum print when a package file named by its metadata could not be fetched: the
// mirror has replaced the release (stale metadata), or the download failed on the way. Measured 2026-10-11 on an
// AlmaLinux e2e host: "dnf install -y openssh-server: exit status 1: [Errno 2] No such file or directory:
// '/var/cache/dnf/baseos-…/packages/openssh-9.9p1-12.el9_8.alma.1.x86_64.rpm'". That version WAS on the mirror, and
// the same install in the same image succeeded afterwards — so it was a failed download, not stale metadata; both
// end the same way for the operator, and both are cured by the same step.
var staleMetadataSigns = []string{
	"No such file or directory: '/var/cache/dnf/",
	"No such file or directory: '/var/cache/yum/",
	"Status code: 404",
	"All mirrors were tried",
	"Cannot download",
}

func looksLikeStaleMetadata(err error) bool {
	msg := err.Error()
	for _, s := range staleMetadataSigns {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}

// mutate runs `<binary> <action> -y <pkg>`. When a package file could not be fetched, it drops the cached metadata
// and retries ONCE — what an operator does by hand (`dnf clean metadata`, then again). Any other failure, and a
// second failure, is returned as it is; when the retry fails too, the error says a refresh was tried.
func (r *rpmPackageManager) mutate(ctx context.Context, action, pkg string) error {
	_, err := r.Runner(ctx, r.binary, action, "-y", pkg)
	if err == nil || !looksLikeStaleMetadata(err) {
		return err
	}
	if _, cerr := r.Runner(ctx, r.binary, "clean", "metadata"); cerr != nil {
		return fmt.Errorf("%w (refreshing the stale metadata failed too: %v)", err, cerr)
	}
	if _, rerr := r.Runner(ctx, r.binary, action, "-y", pkg); rerr != nil {
		return fmt.Errorf("%w (failed again after refreshing the repository metadata)", rerr)
	}
	return nil
}

// rpmStatus reports whether pkg is currently installed and, if so, its
// version, via the underlying rpm database (shared by yum/dnf/dnf5 — all
// three ultimately record installs there). An unknown/not-installed
// package is reported as not-installed rather than an error, matching
// rpm -q's own non-zero-exit response to it.
func (r *rpmPackageManager) rpmStatus(ctx context.Context, pkg string) (installed bool, version string, err error) {
	out, err := r.Runner(ctx, "rpm", "-q", "--queryformat", "%{VERSION}-%{RELEASE}", pkg)
	if err != nil {
		if isExitError(err) {
			return false, "", nil
		}
		return false, "", err
	}
	return true, strings.TrimSpace(string(out)), nil
}

func rpmPackageDescription(binary, ansibleModule, obsoletePeer string) string {
	return "" +
		"Ensure one or more RPM packages are present, absent, or upgraded to the latest " +
		"available version, via " + binary + ". Idempotent: queries the rpm database's current " +
		"status before deciding whether to act. Unit-tested only in this project (no RPM-based " +
		"host in the real verification environment — contrast with apt, this agent's real-" +
		"tested primary target). Supports check_mode via dry_run=true, with one caveat: for " +
		"state=latest, dry_run against an already-installed package conservatively predicts " +
		"changed=true, since determining whether a newer version is truly available would " +
		"itself require a repository query.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: " + ansibleModule + ". Same name/state parameter names (name accepts either " +
		"a single package or a list); a focused subset — Ansible's own module also supports " +
		"enablerepo/disablerepo/update_cache and more, not yet implemented here.\n" +
		"- Chef: the `" + obsoletePeer + "_package`/`package` resources.\n" +
		"- Puppet: the `package` type with `provider => " + binary + "`.\n" +
		"- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.\n" +
		"- Terraform: not applicable — Terraform does not manage OS packages on a running host."
}

// Yum wraps the shared RPM package-manager logic for the yum binary
// (RHEL/CentOS 7 and older Fedora releases). Runner is injectable for
// testing.
type Yum struct{ Runner CommandRunner }

// NewYum returns a Yum module backed by the real yum/rpm binaries.
func NewYum() *Yum { return &Yum{Runner: defaultCommandRunner} }

func (y *Yum) Name() string        { return "yum" }
func (y *Yum) Description() string { return rpmPackageDescription("yum", "ansible.builtin.yum", "yum") }
func (y *Yum) InputSchema() map[string]any {
	return (&rpmPackageManager{}).inputSchema()
}
func (y *Yum) Writes() bool { return true }
func (y *Yum) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	return (&rpmPackageManager{binary: "yum", Runner: y.Runner}).run(ctx, params, dryRun)
}

// Dnf wraps the shared RPM package-manager logic for the dnf binary
// (RHEL/CentOS 8+, modern Fedora). Runner is injectable for testing.
type Dnf struct{ Runner CommandRunner }

// NewDnf returns a Dnf module backed by the real dnf/rpm binaries.
func NewDnf() *Dnf { return &Dnf{Runner: defaultCommandRunner} }

func (d *Dnf) Name() string        { return "dnf" }
func (d *Dnf) Description() string { return rpmPackageDescription("dnf", "ansible.builtin.dnf", "dnf") }
func (d *Dnf) InputSchema() map[string]any {
	return (&rpmPackageManager{}).inputSchema()
}
func (d *Dnf) Writes() bool { return true }
func (d *Dnf) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	return (&rpmPackageManager{binary: "dnf", Runner: d.Runner}).run(ctx, params, dryRun)
}

// Dnf5 wraps the shared RPM package-manager logic for the dnf5 binary
// (dnf's Rust-based rewrite, the default on newer Fedora releases). Runner
// is injectable for testing.
type Dnf5 struct{ Runner CommandRunner }

// NewDnf5 returns a Dnf5 module backed by the real dnf5/rpm binaries.
func NewDnf5() *Dnf5 { return &Dnf5{Runner: defaultCommandRunner} }

func (d *Dnf5) Name() string { return "dnf5" }
func (d *Dnf5) Description() string {
	return rpmPackageDescription("dnf5", "ansible.builtin.dnf5", "dnf")
}
func (d *Dnf5) InputSchema() map[string]any {
	return (&rpmPackageManager{}).inputSchema()
}
func (d *Dnf5) Writes() bool { return true }
func (d *Dnf5) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	return (&rpmPackageManager{binary: "dnf5", Runner: d.Runner}).run(ctx, params, dryRun)
}
