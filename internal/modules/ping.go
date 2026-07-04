package modules

import "context"

// Ping is a trivial connectivity/health check, mirroring
// ansible.builtin.ping. Ansible's real ping confirms a usable Python
// interpreter exists on the far end; this agent has no separate
// interpreter to check (it *is* the thing being reached), so a successful
// response to this tool call is itself the entire proof of connectivity.
type Ping struct{}

// NewPing returns a Ping module.
func NewPing() *Ping { return &Ping{} }

func (p *Ping) Name() string { return "ping" }

func (p *Ping) Description() string {
	return "" +
		"Trivial connectivity/health check — call it to confirm this agent is reachable and " +
		"responding. Takes no parameters, always succeeds, returns {\"ping\": \"pong\"}.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.ping. Ansible's real ping also confirms a usable Python " +
		"interpreter on the managed host; this agent has no separate interpreter to verify — " +
		"a successful tool call response is itself the proof.\n" +
		"- Chef: `knife ssh <host> 'echo pong'`, or simply a successful `chef-client` run.\n" +
		"- Puppet: `puppet agent --test` completing, or a successful catalog compile.\n" +
		"- Salt: the `test.ping` execution module.\n" +
		"- Terraform: not applicable — Terraform has no live-connectivity health-check primitive " +
		"of its own."
}

func (p *Ping) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (p *Ping) Writes() bool { return false }

func (p *Ping) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	return Result{Changed: false, Data: map[string]any{"ping": "pong"}}, nil
}
