package modules

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strings"
)

// Getent queries an NSS database (passwd, group, hosts, ...) via getent,
// mirroring ansible.builtin.getent. Runner is injectable for testing.
type Getent struct {
	Runner CommandRunner
}

// NewGetent returns a Getent module backed by the real getent binary.
func NewGetent() *Getent {
	return &Getent{Runner: defaultCommandRunner}
}

func (m *Getent) Name() string { return "getent" }

func (m *Getent) Description() string {
	return "" +
		"Query an NSS (Name Service Switch) database — passwd, group, hosts, shadow, services, " +
		"and so on — via the `getent` command, optionally for one specific key (e.g. a single " +
		"username). Returns each matched line's raw colon-separated fields plus its name/key. " +
		"Use this to check whether a user/group already exists (and with what uid/gid/home/" +
		"shell) before deciding to call a write-gated `user`/`group` module.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.getent. Same database/key parameters and colon-split field " +
		"semantics; result mirrors ansible_facts['getent_<database>'].\n" +
		"- Chef: Ruby's `Etc.getpwnam`/`Etc.getgrnam` (for passwd/group) in a recipe/library; " +
		"other databases would be queried by shelling out to getent directly.\n" +
		"- Puppet: no dedicated type; Puppet's own `user`/`group` resources read this state " +
		"internally, but ad hoc queries are done via a custom fact or `generate()`.\n" +
		"- Salt: the `user.info`/`group.info` execution modules for passwd/group; other " +
		"databases via `cmd.run('getent ...')`.\n" +
		"- Terraform: not applicable — Terraform does not query remote NSS state directly; this " +
		"would be done via a `null_resource` provisioner shelling out to getent."
}

func (m *Getent) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"database": stringProp(`NSS database to query, e.g. "passwd", "group", "hosts", "shadow", "services".`),
		"key":      stringProp(`Optional specific entry to look up, e.g. a username "deploy". Omit to list every entry in that database (matches the getent CLI's own behavior).`),
	}, "database")
}

func (m *Getent) Writes() bool { return false }

func (m *Getent) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	database, err := stringParam(params, "database", true, "")
	if err != nil {
		return Result{}, err
	}
	key, err := stringParam(params, "key", false, "")
	if err != nil {
		return Result{}, err
	}

	args := []string{database}
	if key != "" {
		args = append(args, key)
	}

	out, err := m.Runner(ctx, "getent", args...)
	if err != nil {
		return Result{}, fmt.Errorf("getent: %w", err)
	}
	return Result{Changed: false, Data: parseGetent(out)}, nil
}

// parseGetent splits each colon-separated getent line into its raw fields,
// with fields[0] (the entry name/key) surfaced separately for convenience.
func parseGetent(out []byte) []map[string]any {
	var entries []map[string]any
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		fields := strings.Split(line, ":")
		entries = append(entries, map[string]any{
			"name":   fields[0],
			"fields": fields,
		})
	}
	if entries == nil {
		entries = []map[string]any{}
	}
	return entries
}
