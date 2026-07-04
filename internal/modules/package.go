package modules

import (
	"context"
	"fmt"
	"os/exec"
)

// Package is a generic, OS-family-agnostic package manager wrapper,
// mirroring ansible.builtin.package. It detects which package manager
// frontend is actually available on this host (checking in order: apt-get,
// dnf, dnf5, yum) and delegates to that family's already-implemented
// module — no separate logic of its own, just dispatch.
type Package struct {
	// LookPath resolves a binary name to a path, like exec.LookPath.
	// Injectable for testing.
	LookPath func(string) (string, error)
	Runner   CommandRunner
}

// NewPackage returns a Package module backed by the real exec.LookPath and
// command runner.
func NewPackage() *Package {
	return &Package{LookPath: exec.LookPath, Runner: defaultCommandRunner}
}

func (p *Package) Name() string { return "package" }

func (p *Package) Description() string {
	return "" +
		"Ensure one or more packages are present, absent, or upgraded to the latest available " +
		"version, using whichever package manager frontend this host actually has (apt-get, " +
		"dnf, dnf5, or yum, checked in that order) — for tasks/playbooks that need to run " +
		"unmodified across both Debian- and RedHat-family hosts. Prefer the specific module " +
		"(apt/dnf/yum/dnf5) when you already know the target distro family; use this one when " +
		"you don't, or when translating a playbook that itself used the generic module. Same " +
		"idempotency/check_mode behavior as whichever underlying module it dispatches to.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.package. Same dispatch-by-detected-package-manager idea; " +
		"same name/state parameter names.\n" +
		"- Chef: the generic `package` resource, which similarly dispatches by platform.\n" +
		"- Puppet: the `package` type without an explicit `provider` (auto-detected).\n" +
		"- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states (Salt's `pkg` state " +
		"module auto-dispatches by the minion's grains).\n" +
		"- Terraform: not applicable — Terraform does not manage OS packages on a running host."
}

func (p *Package) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":    stringArrayProp(`One or more package names, e.g. ["nginx"].`),
		"state":   stringEnumProp(`Desired package state. Default "present".`, "present", "absent", "latest"),
		"dry_run": boolProp("When true, report what would change without issuing any mutating command (check_mode).", false),
	}, "name")
}

func (p *Package) Writes() bool { return true }

func (p *Package) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	backend, err := p.detectBackend()
	if err != nil {
		return Result{}, err
	}
	return backend.Run(ctx, params, dryRun)
}

// detectBackend picks the first available package-manager frontend,
// checked in order: apt-get, dnf, dnf5, yum.
func (p *Package) detectBackend() (Module, error) {
	candidates := []struct {
		binary  string
		backend Module
	}{
		{"apt-get", &Apt{Runner: p.Runner}},
		{"dnf", &Dnf{Runner: p.Runner}},
		{"dnf5", &Dnf5{Runner: p.Runner}},
		{"yum", &Yum{Runner: p.Runner}},
	}
	for _, c := range candidates {
		if _, err := p.LookPath(c.binary); err == nil {
			return c.backend, nil
		}
	}
	return nil, fmt.Errorf("package: no supported package manager found (checked apt-get, dnf, dnf5, yum)")
}
