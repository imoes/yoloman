package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/mutkluge/agentic-mcp/internal/runbook"
	"github.com/mutkluge/agentic-mcp/internal/server"
	"github.com/mutkluge/agentic-mcp/internal/starmodules"
	"github.com/mutkluge/agentic-mcp/internal/starmodules/embedded"
)

// runRunbookCLI runs ONE runbook locally from the command line — the offline counterpart to the agent's
// POST /api/v1/runbook/run, and the runbook-level sibling of `run-module`. It is what the bare-metal
// provisioner uses to execute the restore playbooks in the RAM PE: Bossman parses the Ansible-task YAML
// (services/ansible_playbook.parse_playbook) into the canonical runbook doc and serves it as JSON; this
// reads that doc and runs it through the same runbook.Run the REST path uses.
//
//	agentic-mcpd run-runbook restore-pe-phase.json --modules-dir <dir>
//	agentic-mcpd run-runbook restore-target-phase.json --chroot /mnt/target --modules-dir <dir>
//
// --chroot makes every step run against a system mounted elsewhere: it stamps the reserved
// `_target_root` param onto each step, which the Starlark caps funnel turns into NewChrootCaps — so the
// target-phase modules configure the restored root without staging an agent into it.
func runRunbookCLI(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd run-runbook", flag.ContinueOnError)
	modulesDir := fs.String("modules-dir", "", "also load discovered modules from this dir (native + embedded always load)")
	chroot := fs.String("chroot", "", "run every step against this target root (offline chroot via _target_root)")
	paramsJSON := fs.String("params", "{}", "seed params as JSON, merged over the runbook's own defaults")
	dryRun := fs.Bool("dry-run", false, "check mode: report what would change without changing it")

	// The runbook path is the first positional; support flags before OR after it (Go's flag package
	// stops at the first positional — the same trap fixed in run-module).
	if err := fs.Parse(args); err != nil {
		return err
	}
	var docPath string
	if rest := fs.Args(); len(rest) >= 1 {
		docPath = rest[0]
		if err := fs.Parse(rest[1:]); err != nil {
			return err
		}
	}
	if docPath == "" {
		return fmt.Errorf("usage: agentic-mcpd run-runbook <runbook.json> [--chroot ROOT] [--modules-dir DIR] [--params '{…}'] [--dry-run]")
	}

	raw, err := os.ReadFile(docPath)
	if err != nil {
		return fmt.Errorf("read runbook %q: %w", docPath, err)
	}
	rb, err := canonToRunbook(raw, *chroot)
	if err != nil {
		return err
	}

	reg := server.NewDefaultModuleRegistry() // native Go modules
	if embFS, ferr := embedded.FS(); ferr == nil {
		if mods, _, lerr := starmodules.LoadFS(embFS, true); lerr == nil {
			for _, m := range mods {
				_ = reg.Register(m)
			}
		}
	}
	if *modulesDir != "" {
		mods, _, lerr := starmodules.LoadDir(*modulesDir, true)
		if lerr != nil {
			return fmt.Errorf("loading modules-dir %q: %w", *modulesDir, lerr)
		}
		for _, m := range mods {
			_ = reg.Register(m)
		}
	}

	var seed map[string]any
	if err := json.Unmarshal([]byte(*paramsJSON), &seed); err != nil {
		return fmt.Errorf("--params: %w", err)
	}

	res := runbook.Run(context.Background(), reg, rb, seed, *dryRun)
	out, _ := json.MarshalIndent(res, "", "  ")
	fmt.Println(string(out))
	if res.Status == "failed" {
		return fmt.Errorf("runbook %q failed", res.Runbook)
	}
	return nil
}

// canonStep/canonDoc mirror the canonical runbook doc that services/nt_runbook.Step.to_dict emits
// (Ansible-task shape: the module's params live under "args", the runbook's under "parameters") — the
// Go runbook.Step uses "params", so we map here rather than force the two JSON shapes to match.
type canonStep struct {
	Name     string         `json:"name"`
	Module   string         `json:"module"`
	Args     map[string]any `json:"args"`
	Loop     any            `json:"loop"`
	When     string         `json:"when"`
	Register string         `json:"register"`
	// A GROUP round-trips as block/rescue/always child lists (no module) — see
	// services/nt_runbook.Step.to_dict. Without these fields a grouped task would arrive with an empty
	// module and the run would abort on `unknown module ""`.
	Block  []canonStep `json:"block"`
	Rescue []canonStep `json:"rescue"`
	Always []canonStep `json:"always"`
}

type canonDoc struct {
	Name  string      `json:"name"`
	Steps []canonStep `json:"steps"`
}

func canonToRunbook(raw []byte, chroot string) (runbook.Runbook, error) {
	var doc canonDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return runbook.Runbook{}, fmt.Errorf("parse runbook json: %w", err)
	}
	return runbook.Runbook{Name: doc.Name, Steps: canonSteps(doc.Steps, chroot)}, nil
}

// canonSteps maps the canonical doc's steps to runner steps, recursing into groups so a block's children
// (and its rescue/always branches) get the same treatment — including the chroot stamp.
func canonSteps(steps []canonStep, chroot string) []runbook.Step {
	var out []runbook.Step
	for _, s := range steps {
		params := s.Args
		if params == nil {
			params = map[string]any{}
		}
		if chroot != "" {
			// Every step of a chroot-phase runbook targets the mounted root. Starlark modules honour
			// this reserved key (→ NewChrootCaps); it is inert for anything that ignores it.
			params["_target_root"] = chroot
		}
		out = append(out, runbook.Step{
			Name:     s.Name,
			Module:   s.Module,
			Params:   params,
			Loop:     s.Loop,
			When:     s.When,
			Register: s.Register,
			Block:    canonSteps(s.Block, chroot),
			Rescue:   canonSteps(s.Rescue, chroot),
			Always:   canonSteps(s.Always, chroot),
		})
	}
	return out
}
