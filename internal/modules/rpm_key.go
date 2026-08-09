package modules

import (
	"context"
	"fmt"
	"strings"
)

// RpmKey ensures an RPM package-signing key is present or absent, mirroring
// ansible.builtin.rpm_key. Unlike apt_key (which works around the
// deprecated apt-key binary), rpm --import/-e are the standard, current
// tools for this on RPM-based systems, so this module uses them directly.
//
// Unit-tested only in this project — no RPM-based host in the real
// verification environment (see rpm_pkg.go).
type RpmKey struct {
	Runner CommandRunner
}

// NewRpmKey returns an RpmKey module backed by the real rpm binary.
func NewRpmKey() *RpmKey { return &RpmKey{Runner: defaultCommandRunner} }

func (r *RpmKey) Name() string { return "rpm_key" }

func (r *RpmKey) Description() string {
	return "" +
		"Ensure an RPM package-signing key is present or absent, via `rpm --import`/`rpm -e`. " +
		"`key` is a path or URL to the key file — rpm --import accepts both directly. " +
		"`fingerprint` (the key's full hex fingerprint) is required so the module can check " +
		"whether it's already imported (via its last-8-hex-chars key ID, the identifier rpm " +
		"itself stores imported keys under as a `gpg-pubkey-<keyid>-<date>` pseudo-package) " +
		"without re-importing it. Idempotent — only calls rpm when the key's presence doesn't " +
		"already match state. Supports check_mode via dry_run=true. Unit-tested only in this " +
		"project — no RPM-based host in the real verification environment (contrast with " +
		"apt_key, which is real-tested on Debian).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.rpm_key. Same key/fingerprint/state semantics.\n" +
		"- Chef: the `yum_repository` resource's `gpgkey` property (imported implicitly on " +
		"first repo use), or a `execute` resource wrapping `rpm --import`.\n" +
		"- Puppet: the puppetlabs-stdlib module conventions or a raw `exec` wrapping `rpm " +
		"--import` — no core equivalent.\n" +
		"- Salt: the `pkgrepo.managed` state's `gpgkey` handling on RPM-based minions.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's package " +
		"manager trust store."
}

func (r *RpmKey) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"key":         stringProp("Path or URL to the key file. Required for state=present."),
		"fingerprint": stringProp("The key's full hex fingerprint, used to check presence via its last-8-hex-char key ID."),
		"state":       stringEnumProp(`Whether the key should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":     boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "fingerprint")
}

func (r *RpmKey) Writes() bool { return true }

func (r *RpmKey) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	key, err := stringParam(params, "key", false, "")
	if err != nil {
		return Result{}, err
	}
	fingerprint, err := stringParam(params, "fingerprint", true, "")
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
	if len(fingerprint) < 8 {
		return Result{}, fmt.Errorf("fingerprint: must be at least 8 hex characters")
	}
	keyID := strings.ToLower(fingerprint[len(fingerprint)-8:])

	pkgName, present, err := r.lookupKey(ctx, keyID)
	if err != nil {
		return Result{}, err
	}

	if state == "absent" {
		if !present {
			return Result{Changed: false, Msg: "already absent", Data: map[string]any{"fingerprint": fingerprint}}, nil
		}
		if !dryRun {
			if _, err := r.Runner(ctx, "rpm", "-e", pkgName); err != nil {
				return Result{}, fmt.Errorf("rpm_key: removing %s: %w", pkgName, err)
			}
		}
		return Result{Changed: true, Msg: "removed", Data: map[string]any{"fingerprint": fingerprint}}, nil
	}

	if present {
		return Result{Changed: false, Msg: "already present", Data: map[string]any{"fingerprint": fingerprint}}, nil
	}
	if key == "" {
		return Result{}, fmt.Errorf("key: required when state=present and the key is not already imported")
	}
	if !dryRun {
		if _, err := r.Runner(ctx, "rpm", "--import", key); err != nil {
			return Result{}, fmt.Errorf("rpm_key: importing %s: %w", key, err)
		}
	}
	return Result{Changed: true, Msg: "imported", Data: map[string]any{"fingerprint": fingerprint}}, nil
}

// lookupKey checks whether a gpg-pubkey-<keyID>-* pseudo-package is
// currently installed, returning its exact package name if so (needed for
// rpm -e, which requires an exact NVR, not just the keyID prefix).
func (r *RpmKey) lookupKey(ctx context.Context, keyID string) (pkgName string, present bool, err error) {
	out, err := r.Runner(ctx, "rpm", "-qa", "gpg-pubkey-"+keyID+"-*")
	if err != nil {
		if isExitError(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("rpm_key: querying key %s: %w", keyID, err)
	}
	name := strings.TrimSpace(string(out))
	if name == "" {
		return "", false, nil
	}
	// rpm -qa can list multiple matches on one line each; take the first.
	name = strings.SplitN(name, "\n", 2)[0]
	return name, true, nil
}
