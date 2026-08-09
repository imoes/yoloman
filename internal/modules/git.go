package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Git ensures a git repository is cloned/checked out at a desired
// version, mirroring ansible.builtin.git. It is idempotent: if dest is
// already a git working copy, it fetches and checks out the desired
// version only if that differs from the current HEAD; otherwise it clones.
type Git struct {
	Runner CommandRunner
}

// NewGit returns a Git module backed by the real git binary.
func NewGit() *Git { return &Git{Runner: defaultCommandRunner} }

func (g *Git) Name() string { return "git" }

func (g *Git) Description() string {
	return "" +
		"Ensure a git repository is cloned at dest and checked out to a desired version " +
		"(branch, tag, or commit). Idempotent — if dest is already a working copy, only " +
		"fetches/checks out when the resolved commit differs from the current HEAD; otherwise " +
		"clones fresh. Supports check_mode via dry_run=true (a real check requires a network " +
		"fetch to know the remote's current state, so dry_run against an existing clone " +
		"conservatively predicts changed=true — the same trade-off documented for the RPM " +
		"package modules' state=latest).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.git. Same repo/dest/version/depth/force parameter names (a " +
		"focused subset — Ansible also supports refspec/key_file/accept_hostkey and more, not " +
		"implemented here).\n" +
		"- Chef: the `git` resource.\n" +
		"- Puppet: the puppetlabs-vcsrepo module's `vcsrepo` type with `provider => git`.\n" +
		"- Salt: the `git.latest` state.\n" +
		"- Terraform: not applicable — Terraform does not manage arbitrary file-tree state on a " +
		"running host; the closest analogue is a provisioner shelling out to git."
}

func (g *Git) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"repo":    stringProp("Repository URL to clone from."),
		"dest":    stringProp(`Destination directory, e.g. "/opt/app".`),
		"version": stringProp(`Branch, tag, or commit to check out. Default "HEAD".`),
		"depth":   stringProp("Optional shallow-clone depth, as a string, e.g. \"1\"."),
		"force":   boolProp("When true, discard any local modifications before checking out. Default false.", false),
		"dry_run": boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "repo", "dest")
}

func (g *Git) Writes() bool { return true }

func (g *Git) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	repo, err := stringParam(params, "repo", true, "")
	if err != nil {
		return Result{}, err
	}
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	version, err := stringParam(params, "version", false, "HEAD")
	if err != nil {
		return Result{}, err
	}
	depth, err := stringParam(params, "depth", false, "")
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

	_, statErr := os.Stat(filepath.Join(dest, ".git"))
	isRepo := statErr == nil

	if !isRepo {
		if dryRun {
			return Result{Changed: true, Msg: "would clone (dry run)", Data: map[string]any{"dest": dest}}, nil
		}
		args := []string{"clone"}
		if depth != "" {
			args = append(args, "--depth", depth)
		}
		if version != "" && version != "HEAD" {
			args = append(args, "--branch", version)
		}
		args = append(args, repo, dest)
		if _, err := g.Runner(ctx, "git", args...); err != nil {
			return Result{}, fmt.Errorf("git: cloning %s: %w", repo, err)
		}
		return Result{Changed: true, Msg: "cloned", Data: map[string]any{"dest": dest}}, nil
	}

	before, err := g.currentCommit(ctx, dest)
	if err != nil {
		return Result{}, err
	}

	if dryRun {
		return Result{Changed: true, Msg: "would fetch/checkout (dry run)", Data: map[string]any{"dest": dest, "commit": before}}, nil
	}

	if force {
		if _, err := g.Runner(ctx, "git", "-C", dest, "reset", "--hard"); err != nil {
			return Result{}, fmt.Errorf("git: resetting %s: %w", dest, err)
		}
	}
	if _, err := g.Runner(ctx, "git", "-C", dest, "fetch", "origin"); err != nil {
		return Result{}, fmt.Errorf("git: fetching %s: %w", dest, err)
	}
	// Prefer the freshly fetched remote-tracking ref (e.g. "origin/main")
	// over the bare branch name: `git checkout <branch>` on a branch
	// that's already checked out locally just re-selects it without
	// advancing it to match what was just fetched — checking out the
	// remote-tracking ref directly (a detached HEAD at that exact commit)
	// is what actually moves dest's working tree forward. Falls back to
	// the literal ref for a tag or commit, which has no "origin/" form.
	target := version
	if _, err := g.Runner(ctx, "git", "-C", dest, "rev-parse", "--verify", "origin/"+version); err == nil {
		target = "origin/" + version
	}
	if _, err := g.Runner(ctx, "git", "-C", dest, "checkout", target); err != nil {
		return Result{}, fmt.Errorf("git: checking out %s in %s: %w", version, dest, err)
	}

	after, err := g.currentCommit(ctx, dest)
	if err != nil {
		return Result{}, err
	}

	changed := before != after
	msg := "already at desired version"
	if changed {
		msg = "checked out new version"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest, "commit": after}}, nil
}

// currentCommit returns dest's current HEAD commit hash.
func (g *Git) currentCommit(ctx context.Context, dest string) (string, error) {
	out, err := g.Runner(ctx, "git", "-C", dest, "rev-parse", "HEAD")
	if err != nil {
		return "", fmt.Errorf("git: reading HEAD of %s: %w", dest, err)
	}
	return strings.TrimSpace(string(out)), nil
}
