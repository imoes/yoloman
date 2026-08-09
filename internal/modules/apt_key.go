package modules

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// HTTPGetFunc fetches url's body. Injectable for testing (real
// implementation wraps http.Get).
type HTTPGetFunc func(url string) ([]byte, error)

func defaultHTTPGet(url string) ([]byte, error) {
	resp, err := http.Get(url) //nolint:gosec // url is operator-supplied module input, not attacker-controlled
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %s", resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// AptKey ensures an APT signing key is present or absent, mirroring
// ansible.builtin.apt_key — but implemented via `gpg --dearmor` writing
// directly to a keyring file under /etc/apt/trusted.gpg.d/, rather than the
// `apt-key` binary itself, which is deprecated and removed on newer
// Debian/Ubuntu releases. This is the same approach Debian's own
// documentation recommends in apt-key's place.
type AptKey struct {
	RunnerStdin CommandRunnerWithStdin
	HTTPGet     HTTPGetFunc
	// KeyringDir is where <id>.gpg files are read/written. Defaults to
	// /etc/apt/trusted.gpg.d; overridable so tests don't need root.
	KeyringDir string
}

// NewAptKey returns an AptKey module backed by the real gpg binary, a real
// HTTP client, and /etc/apt/trusted.gpg.d.
func NewAptKey() *AptKey {
	return &AptKey{
		RunnerStdin: defaultCommandRunnerWithStdin,
		HTTPGet:     defaultHTTPGet,
		KeyringDir:  "/etc/apt/trusted.gpg.d",
	}
}

func (a *AptKey) Name() string { return "apt_key" }

func (a *AptKey) Description() string {
	return "" +
		"Ensure an APT signing key is present or absent, identified by `id` (used as the " +
		"keyring filename). Provide the key as armored text via `data`, or fetch it from `url`. " +
		"Implemented via `gpg --dearmor` writing to /etc/apt/trusted.gpg.d/<id>.gpg rather than " +
		"the `apt-key` command itself, which upstream Debian/Ubuntu have deprecated and removed " +
		"from newer releases — this is the same replacement approach Debian's own release notes " +
		"recommend. Idempotent — only writes when the dearmored key bytes differ from the " +
		"keyring file's current content. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.apt_key. Ansible's own module is itself marked deprecated " +
		"for the same reason (apt-key removal); same id/data/url/state parameter names.\n" +
		"- Chef: the `apt_repository` resource's `key` property, or a `execute` resource " +
		"wrapping `gpg --dearmor`.\n" +
		"- Puppet: the puppetlabs-apt module's `apt::key` type.\n" +
		"- Salt: the `pkgrepo.managed` state's `key_url`/`aptkey_id` handling.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's package " +
		"manager trust store."
}

func (a *AptKey) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"id":      stringProp(`Key identifier, used as the keyring filename (<id>.gpg), e.g. "docker".`),
		"data":    stringProp("Armored (ASCII) key text. Mutually exclusive with url. Required for state=present unless url is given."),
		"url":     stringProp("URL to fetch the armored key from. Mutually exclusive with data."),
		"state":   stringEnumProp(`Whether the key should be present or absent. Default "present".`, "present", "absent"),
		"dry_run": boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "id")
}

func (a *AptKey) Writes() bool { return true }

func (a *AptKey) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	id, err := stringParam(params, "id", true, "")
	if err != nil {
		return Result{}, err
	}
	data, err := stringParam(params, "data", false, "")
	if err != nil {
		return Result{}, err
	}
	url, err := stringParam(params, "url", false, "")
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
	if strings.ContainsAny(id, "/\\") {
		return Result{}, fmt.Errorf("id: must not contain path separators")
	}
	path := filepath.Join(a.KeyringDir, id+".gpg")

	if state == "absent" {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return Result{Changed: false, Msg: "already absent", Data: map[string]any{"id": id}}, nil
		}
		if !dryRun {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return Result{}, fmt.Errorf("apt_key: removing %q: %w", path, err)
			}
		}
		return Result{Changed: true, Msg: "removed", Data: map[string]any{"id": id}}, nil
	}

	if (data == "") == (url == "") {
		return Result{}, fmt.Errorf("apt_key: exactly one of data or url must be given for state=present")
	}
	armored := data
	if url != "" {
		body, err := a.HTTPGet(url)
		if err != nil {
			return Result{}, fmt.Errorf("apt_key: fetching %q: %w", url, err)
		}
		armored = string(body)
	}

	dearmored, err := a.RunnerStdin(ctx, armored, "gpg", "--dearmor")
	if err != nil {
		return Result{}, fmt.Errorf("apt_key: dearmoring key %q: %w", id, err)
	}

	current, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("apt_key: reading %q: %w", path, readErr)
	}
	if bytes.Equal(current, dearmored) {
		return Result{Changed: false, Msg: "already up to date", Data: map[string]any{"id": id}}, nil
	}

	if !dryRun {
		if err := os.MkdirAll(a.KeyringDir, 0o755); err != nil {
			return Result{}, fmt.Errorf("apt_key: creating %q: %w", a.KeyringDir, err)
		}
		if err := os.WriteFile(path, dearmored, 0o644); err != nil {
			return Result{}, fmt.Errorf("apt_key: writing %q: %w", path, err)
		}
	}
	return Result{Changed: true, Msg: "written", Data: map[string]any{"id": id}}, nil
}
