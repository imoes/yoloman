package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Subversion ensures a Subversion working copy is checked out/updated at a
// desired revision, mirroring ansible.builtin.subversion. It is idempotent:
// if dest is already a working copy, it updates only if that changes the
// checked-out revision; otherwise it checks out fresh.
type Subversion struct {
	Runner CommandRunner
}

// NewSubversion returns a Subversion module backed by the real svn binary.
func NewSubversion() *Subversion { return &Subversion{Runner: defaultCommandRunner} }

func (s *Subversion) Name() string { return "subversion" }

func (s *Subversion) Description() string {
	return "" +
		"Ensure a Subversion working copy is checked out at dest and updated to a desired " +
		"revision. Idempotent — if dest is already a working copy, only runs `svn update` (and " +
		"reports changed based on whether the revision actually moved); otherwise checks out " +
		"fresh. Supports check_mode via dry_run=true (a real check requires contacting the " +
		"server to know its current revision, so dry_run against an existing checkout " +
		"conservatively predicts changed=true, the same trade-off documented for git/state=latest " +
		"package modules).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.subversion. Same repo/dest/revision parameter names (a " +
		"focused subset — Ansible also supports username/password/export, not implemented " +
		"here).\n" +
		"- Chef: the `subversion` resource.\n" +
		"- Puppet: the puppetlabs-vcsrepo module's `vcsrepo` type with `provider => svn`.\n" +
		"- Salt: the `svn.latest` state.\n" +
		"- Terraform: not applicable — see the git module's description for the general " +
		"reasoning."
}

func (s *Subversion) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"repo":     stringProp("Subversion repository URL to check out from."),
		"dest":     stringProp(`Destination directory, e.g. "/opt/app".`),
		"revision": stringProp(`Revision to check out, e.g. "HEAD" or "1234". Default "HEAD".`),
		"force":    boolProp("When true, discard any local modifications before updating (svn revert). Default false.", false),
		"dry_run":  boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "repo", "dest")
}

func (s *Subversion) Writes() bool { return true }

func (s *Subversion) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	repo, err := stringParam(params, "repo", true, "")
	if err != nil {
		return Result{}, err
	}
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	revision, err := stringParam(params, "revision", false, "HEAD")
	if err != nil {
		return Result{}, err
	}
	force, err := boolParam(params, "force", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	_, statErr := os.Stat(filepath.Join(dest, ".svn"))
	isCheckout := statErr == nil

	if !isCheckout {
		if dryRun {
			return Result{Changed: true, Msg: "would check out (dry run)", Data: map[string]any{"dest": dest}}, nil
		}
		args := []string{"checkout", "--revision", revision, repo, dest}
		if _, err := s.Runner(ctx, "svn", args...); err != nil {
			return Result{}, fmt.Errorf("subversion: checking out %s: %w", repo, err)
		}
		after, err := s.currentRevision(ctx, dest)
		if err != nil {
			return Result{}, err
		}
		return Result{Changed: true, Msg: "checked out", Data: map[string]any{"dest": dest, "revision": after}}, nil
	}

	before, err := s.currentRevision(ctx, dest)
	if err != nil {
		return Result{}, err
	}

	if dryRun {
		return Result{Changed: true, Msg: "would update (dry run)", Data: map[string]any{"dest": dest, "revision": before}}, nil
	}

	if force {
		if _, err := s.Runner(ctx, "svn", "revert", "--recursive", dest); err != nil {
			return Result{}, fmt.Errorf("subversion: reverting %s: %w", dest, err)
		}
	}
	if _, err := s.Runner(ctx, "svn", "update", "--revision", revision, dest); err != nil {
		return Result{}, fmt.Errorf("subversion: updating %s: %w", dest, err)
	}

	after, err := s.currentRevision(ctx, dest)
	if err != nil {
		return Result{}, err
	}

	changed := before != after
	msg := "already at desired revision"
	if changed {
		msg = "updated to new revision"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest, "revision": after}}, nil
}

// currentRevision returns dest's current checked-out revision number via
// `svn info`.
func (s *Subversion) currentRevision(ctx context.Context, dest string) (string, error) {
	out, err := s.Runner(ctx, "svn", "info", dest)
	if err != nil {
		return "", fmt.Errorf("subversion: reading info of %s: %w", dest, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if v, ok := strings.CutPrefix(line, "Revision: "); ok {
			return strings.TrimSpace(v), nil
		}
	}
	return "", fmt.Errorf("subversion: could not find Revision in svn info output for %s", dest)
}
