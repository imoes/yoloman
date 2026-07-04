package modules

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// KnownHosts ensures an SSH known_hosts entry is present or absent,
// mirroring ansible.builtin.known_hosts. It is idempotent: entries are
// identified by their hostname field (the first whitespace-separated
// field of each line), so re-running with a different key replaces the
// same entry rather than adding a duplicate.
type KnownHosts struct{}

// NewKnownHosts returns a KnownHosts module.
func NewKnownHosts() *KnownHosts { return &KnownHosts{} }

func (k *KnownHosts) Name() string { return "known_hosts" }

func (k *KnownHosts) Description() string {
	return "" +
		"Ensure an SSH known_hosts entry is present or absent, identified by hostname (the " +
		"entry's first field) rather than its full line — so re-running with a different host " +
		"key replaces the same entry instead of adding a duplicate stale one. Idempotent — a " +
		"repeat call with the same key reports changed=false. Supports check_mode via " +
		"dry_run=true. Host key hashing (ssh-keygen -H style) is not implemented — entries are " +
		"always written in plain hostname form, matching this module's real Ansible default " +
		"(hash_host=false).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.known_hosts. Same name/key/path/state parameter names (a " +
		"focused subset — Ansible also supports hash_host, not implemented here).\n" +
		"- Chef: no single built-in resource; typically composed from `Chef::Util::FileEdit` in " +
		"a custom resource, or the community 'ssh_known_hosts' cookbook.\n" +
		"- Puppet: the puppetlabs-stdlib module conventions, or the sshkeys core type on some " +
		"platforms.\n" +
		"- Salt: the `ssh.set_known_host`/`ssh.rm_known_host` execution modules.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's SSH trust " +
		"store."
}

func (k *KnownHosts) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringProp(`Hostname the entry is for, e.g. "github.com".`),
		"key":     stringProp(`The full known_hosts line, e.g. "github.com ssh-ed25519 AAAA...". Required for state=present.`),
		"path":    stringProp(`Target known_hosts file. Default "/etc/ssh/ssh_known_hosts".`),
		"state":   stringEnumProp(`Whether the entry should be present or absent. Default "present".`, "present", "absent"),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "name")
}

func (k *KnownHosts) Writes() bool { return true }

func (k *KnownHosts) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	key, err := stringParam(params, "key", false, "")
	if err != nil {
		return Result{}, err
	}
	path, err := stringParam(params, "path", false, "/etc/ssh/ssh_known_hosts")
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
	if state == "present" && key == "" {
		return Result{}, fmt.Errorf("key: required when state=present")
	}

	raw, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return Result{}, fmt.Errorf("known_hosts: reading %q: %w", path, err)
	}
	var lines []string
	if len(raw) > 0 {
		lines = strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	}

	matchIdx := -1
	for i, l := range lines {
		fields := strings.Fields(l)
		if len(fields) > 0 && fields[0] == name {
			matchIdx = i
			break
		}
	}

	var newLines []string
	var changed bool
	if state == "absent" {
		if matchIdx == -1 {
			return Result{Changed: false, Msg: "already absent", Data: map[string]any{"name": name}}, nil
		}
		newLines = append(append([]string{}, lines[:matchIdx]...), lines[matchIdx+1:]...)
		changed = true
	} else {
		if matchIdx != -1 {
			if lines[matchIdx] == key {
				return Result{Changed: false, Msg: "already up to date", Data: map[string]any{"name": name}}, nil
			}
			newLines = append([]string{}, lines...)
			newLines[matchIdx] = key
		} else {
			newLines = append(append([]string{}, lines...), key)
		}
		changed = true
	}

	if changed && !dryRun {
		content := ""
		if len(newLines) > 0 {
			content = strings.Join(newLines, "\n") + "\n"
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return Result{}, fmt.Errorf("known_hosts: writing %q: %w", path, err)
		}
	}

	return Result{Changed: true, Msg: "entry " + state, Data: map[string]any{"name": name}}, nil
}
