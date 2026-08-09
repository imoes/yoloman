package modules

import (
	"context"
	"fmt"
	"strings"
)

// Script runs a script file already present on this host, mirroring
// ansible.builtin.script — but as a thin wrapper over Command's execution
// (see command.go), not a real file copy. Real Ansible's script module
// copies a script from the control node to the managed host, then runs it;
// this agent has no such separate control-node filesystem (it *is* both
// ends), so "run this script" reduces to just running it, the same
// operation command already performs.
type Script struct{ *Command }

// NewScript returns a Script module (a thin wrapper over Command).
func NewScript() *Script { return &Script{Command: NewCommand()} }

func (s *Script) Name() string { return "script" }

func (s *Script) Description() string {
	return "" +
		"Run a script file already present on this host (with optional arguments), capturing " +
		"rc/stdout/stderr. In real Ansible, script copies a file FROM the control node TO the " +
		"managed host before running it; this agent has no such separate control-node " +
		"filesystem, so this reduces to running an already-present executable — the same " +
		"operation the command module performs (use command directly for an equivalent " +
		"call; script exists for drop-in familiarity with real Ansible task syntax that " +
		"names it explicitly). Like command, **a non-zero exit code is not raised as a tool " +
		"error** — check data.rc yourself.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.script. Same intent (run a script with arguments); no " +
		"control-node-to-managed-host copy step here, since there is no separate control-node " +
		"filesystem.\n" +
		"- Chef/Puppet/Salt/Terraform: see command's description — the underlying operation " +
		"(execute an already-present script) is identical."
}

func (s *Script) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"cmd":     stringProp(`Script path plus arguments, split on whitespace, e.g. "/opt/app/setup.sh --force".`),
		"chdir":   stringProp("Optional working directory to run the script in."),
		"dry_run": boolProp("When true, do not execute the script at all; report changed=true as a prediction only (check_mode).", false),
	}, "cmd")
}

func (s *Script) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	cmd, err := stringParam(params, "cmd", true, "")
	if err != nil {
		return Result{}, err
	}
	fields := strings.Fields(cmd)
	if len(fields) == 0 {
		return Result{}, fmt.Errorf("cmd: must not be empty")
	}
	return s.Command.Run(ctx, map[string]any{
		"argv":    fields,
		"chdir":   params["chdir"],
		"dry_run": params["dry_run"],
	}, dryRunArg)
}
