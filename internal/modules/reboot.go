package modules

import (
	"context"
	"fmt"
)

// Reboot issues a reboot of this host, mirroring ansible.builtin.reboot —
// but with an important architectural difference, stated plainly: real
// Ansible runs from a separate control node over SSH, so after triggering
// the reboot it can poll the target until it reappears and report the
// whole operation as complete. This agent *is* the target: the process
// handling this very call is terminated the moment the reboot actually
// happens, so there is no possibility of waiting for the host to come back
// up from inside itself. This module therefore only issues the reboot
// command and returns immediately — the caller (an external MCP/REST
// client, or a human) is responsible for polling the host's return by
// other means (e.g. wait_for against a port on this same host, called from
// a separate session/client after this one necessarily disconnects).
type Reboot struct {
	Runner CommandRunner
}

// NewReboot returns a Reboot module backed by the real shutdown binary.
func NewReboot() *Reboot { return &Reboot{Runner: defaultCommandRunner} }

func (r *Reboot) Name() string { return "reboot" }

func (r *Reboot) Description() string {
	return "" +
		"Reboot this host via `shutdown -r now`. **Architectural limitation, stated plainly**: " +
		"real Ansible's reboot module runs from a separate control node over SSH and can " +
		"therefore poll the target until it reappears before reporting success; this agent runs " +
		"*on* the host being rebooted, so the process handling this very call is terminated the " +
		"moment the reboot happens — there is no possibility of waiting for the host to come " +
		"back up from inside itself. This module only issues the reboot command and returns " +
		"immediately; verifying the host actually came back up is the caller's responsibility " +
		"(e.g. a separate later call, from a new connection, to wait_for or ping). Like " +
		"restarted/reloaded on the systemd module, this is inherently an action rather than an " +
		"idempotent state comparison, so it always reports changed=true once issued. Supports " +
		"check_mode via dry_run=true (does not actually reboot).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.reboot. Same msg parameter name; Ansible's post-reboot " +
		"connectivity polling has no equivalent here, for the architectural reason above.\n" +
		"- Chef: the `reboot` resource.\n" +
		"- Puppet: the `reboot` type (puppetlabs-reboot module).\n" +
		"- Salt: the `system.reboot` execution module.\n" +
		"- Terraform: not applicable — Terraform does not manage live host power state."
}

func (r *Reboot) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"msg":     stringProp(`Broadcast message shown to logged-in users before rebooting. Default "Reboot initiated by agentic-mcp".`),
		"dry_run": boolProp("When true, do not actually reboot; report changed=true as a prediction only (check_mode).", false),
	})
}

func (r *Reboot) Writes() bool { return true }

func (r *Reboot) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	msg, err := stringParam(params, "msg", false, "Reboot initiated by agentic-mcp")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if dryRun {
		return Result{Changed: true, Msg: "would reboot (dry run)", Data: map[string]any{"msg": msg}}, nil
	}

	args := []string{"-r", "now"}
	if msg != "" {
		args = append(args, msg)
	}
	if _, err := r.Runner(ctx, "shutdown", args...); err != nil {
		return Result{}, fmt.Errorf("reboot: issuing shutdown: %w", err)
	}

	return Result{Changed: true, Msg: "reboot issued", Data: map[string]any{"msg": msg}}, nil
}
