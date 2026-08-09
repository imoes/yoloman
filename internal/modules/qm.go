package modules

import (
	"context"
	"fmt"
	"strings"
)

// QM exposes the FULL Proxmox VE `qm` CLI as one module: any subcommand
// (start/stop/shutdown/reboot/reset/suspend/resume, snapshot/delsnapshot/
// rollback/listsnapshot, migrate, clone, resize, set, config, status, list, …)
// is reachable via command + args, so the whole qm surface is available
// through a single tool. Read subcommands run even in check_mode; mutating
// ones are write-gated and skipped under dry_run. Runner is injectable.
type QM struct {
	Runner CommandRunner
}

// NewQM returns a QM module backed by the real qm CLI.
func NewQM() *QM { return &QM{Runner: defaultCommandRunner} }

func (m *QM) Name() string { return "qm" }

// qmReadOnly are the qm subcommands that only read state — they run even under
// dry_run and report changed=false. Everything else is treated as mutating.
var qmReadOnly = map[string]bool{
	"status": true, "list": true, "listsnapshot": true, "config": true,
	"pending": true, "showcmd": true, "cloudinit": true,
}

func (m *QM) Description() string {
	return "" +
		"Run any Proxmox VE `qm` subcommand on this node via the local CLI — the full qm surface " +
		"in one tool. Set command to the subcommand and args to the rest of the command line, e.g. " +
		"command=\"snapshot\" args=[\"100\",\"pre-upgrade\",\"--description\",\"before upgrade\"], or " +
		"command=\"migrate\" args=[\"100\",\"pve2\",\"--online\"], or command=\"start\" args=[\"100\"]. " +
		"Common subcommands: start, stop, shutdown, reboot, reset, suspend, resume (power); " +
		"snapshot, delsnapshot, rollback, listsnapshot (snapshots); migrate; clone; resize; set; " +
		"config; status; list. Read subcommands (status/list/config/listsnapshot/pending/showcmd/" +
		"cloudinit) run even in check_mode and report changed=false; every other subcommand is " +
		"mutating — write-gated, skipped under dry_run=true, reported changed=true. Returns " +
		"{rc, stdout, stderr}. Idempotency is the caller's responsibility (this is a raw CLI " +
		"passthrough). List VMs/detect the hypervisor with the read-only virt_facts module; this " +
		"is LOCAL node control, distinct from the API-based community.general.proxmox_kvm."
}

func (m *QM) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"command": stringProp("The qm subcommand, e.g. \"start\", \"snapshot\", \"migrate\", \"clone\", \"resize\", \"set\", \"config\", \"status\", \"list\"."),
		"args": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "string"},
			"description": "Positional arguments and flags after the subcommand, e.g. [\"100\",\"pve2\",\"--online\"].",
		},
		"dry_run": boolProp("When true, mutating subcommands are reported but not executed (check_mode). Read subcommands still run.", false),
	}, "command")
}

func (m *QM) Writes() bool { return true }

func (m *QM) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	return dispatchCLI(ctx, m.Runner, "qm", qmReadOnly, params, dryRunArg)
}

// dispatchCLI is the shared generic-CLI runtime for the qm and virsh modules:
// it validates command+args, classifies read vs mutating via readOnly, honors
// dry_run for mutating subcommands, and returns the process result as data.
func dispatchCLI(ctx context.Context, runner CommandRunner, bin string, readOnly map[string]bool, params map[string]any, dryRunArg bool) (Result, error) {
	command, err := stringParam(params, "command", true, "")
	if err != nil {
		return Result{}, err
	}
	command = strings.TrimSpace(command)
	if command == "" {
		return Result{}, fmt.Errorf("command must not be empty")
	}
	args, err := stringSliceParam(params, "args", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	argv := append([]string{command}, args...)
	data := map[string]any{"command": command, "args": args}

	if readOnly[command] {
		out, err := runner(ctx, bin, argv...)
		if err != nil && !isExitError(err) {
			return Result{}, fmt.Errorf("%s %s: %w", bin, command, err)
		}
		data["stdout"] = string(out)
		if err != nil {
			data["rc"] = "nonzero"
			data["error"] = strings.TrimSpace(err.Error())
		}
		return Result{Changed: false, Msg: bin + " " + command, Data: data}, nil
	}

	// Mutating subcommand.
	if dryRun {
		data["skipped"] = true
		return Result{Changed: true, Msg: "would run " + bin + " " + strings.Join(argv, " "), Data: data}, nil
	}
	out, err := runner(ctx, bin, argv...)
	if err != nil {
		return Result{}, fmt.Errorf("%s %s: %w", bin, command, err)
	}
	data["stdout"] = string(out)
	return Result{Changed: true, Msg: bin + " " + command, Data: data}, nil
}
