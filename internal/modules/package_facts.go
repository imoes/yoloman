package modules

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strings"
)

// PackageFacts lists installed packages via dpkg-query, mirroring
// ansible.builtin.package_facts on Debian-family systems (the agent's
// primary packaging target). Runner is injectable for testing.
type PackageFacts struct {
	Runner CommandRunner
}

// NewPackageFacts returns a PackageFacts module backed by the real dpkg-query.
func NewPackageFacts() *PackageFacts {
	return &PackageFacts{Runner: defaultCommandRunner}
}

func (m *PackageFacts) Name() string { return "package_facts" }

func (m *PackageFacts) Description() string {
	return "" +
		"Enumerate every package installed on the host (name, version, architecture). Uses dpkg " +
		"on Debian/Ubuntu and falls back to rpm on RHEL/Fedora-family systems. Takes no parameters — it always " +
		"returns the full list; filter client-side for a specific package. Use this to check " +
		"whether a desired package is already at the right version before deciding to call the " +
		"write-gated `apt`/`package` module.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.package_facts (with use=apt). Same underlying dpkg query; " +
		"result shape mirrors ansible_facts['packages'].\n" +
		"- Chef: the Ohai `packages` plugin (node['packages']).\n" +
		"- Puppet: Facter's package facts, or `puppet resource package`.\n" +
		"- Salt: the `pkg.list_pkgs` execution module.\n" +
		"- Terraform: not applicable — Terraform does not introspect installed packages on a " +
		"running host; package presence is normally asserted, not queried, via a provisioner."
}

func (m *PackageFacts) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (m *PackageFacts) Writes() bool { return false }

func (m *PackageFacts) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	// Debian/Ubuntu via dpkg; fall back to rpm on RHEL/Fedora-family hosts.
	out, err := m.Runner(ctx, "dpkg-query", "-W", "-f", "${Package}\t${Version}\t${Architecture}\n")
	if err == nil {
		return Result{Changed: false, Data: parseDpkgQuery(out)}, nil
	}
	rpmOut, rpmErr := m.Runner(ctx, "rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n")
	if rpmErr != nil {
		return Result{}, fmt.Errorf("package_facts: neither dpkg-query (%v) nor rpm (%v) succeeded", err, rpmErr)
	}
	return Result{Changed: false, Data: parseDpkgQuery(rpmOut)}, nil
}

// parseDpkgQuery parses tab-separated "name\tversion\tarch" lines as
// produced by the -f format string in Run.
func parseDpkgQuery(out []byte) []map[string]any {
	var pkgs []map[string]any
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 3 {
			continue
		}
		pkgs = append(pkgs, map[string]any{
			"name":    fields[0],
			"version": fields[1],
			"arch":    fields[2],
		})
	}
	if pkgs == nil {
		pkgs = []map[string]any{}
	}
	return pkgs
}
