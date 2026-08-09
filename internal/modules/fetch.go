package modules

import "context"

// Fetch reads a file's contents from the managed host, mirroring
// ansible.builtin.fetch — but implemented as a thin alias over Slurp
// (see slurp.go), not a real file copy. Ansible's real fetch copies a file
// FROM the managed host TO the separate machine running Ansible; this
// agent has no such separate control-node filesystem (it *is* both ends),
// so "fetch a file's content" and "slurp a file's content" are the same
// operation here — the only difference is the parameter name (`src`
// instead of `path`), kept for drop-in familiarity with real Ansible task
// syntax.
type Fetch struct{ *Slurp }

// NewFetch returns a Fetch module (alias of Slurp).
func NewFetch() *Fetch { return &Fetch{Slurp: NewSlurp()} }

func (f *Fetch) Name() string { return "fetch" }

func (f *Fetch) Description() string {
	return "" +
		"Read a file's entire contents from this host, returned base64-encoded. In real " +
		"Ansible, fetch copies a file FROM the managed host TO the separate machine running " +
		"Ansible; this agent has no such separate control-node filesystem, so fetch and slurp " +
		"(see that tool) are the same operation here — use whichever name matches the task " +
		"syntax you're translating from.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.fetch. Same intent (retrieve a file's content), different " +
		"parameter name (`src` here vs. `dest` being irrelevant since there's no separate " +
		"destination filesystem to copy into).\n" +
		"- Chef/Puppet/Salt/Terraform: see slurp's description — the underlying operation " +
		"(read a live file's content) is identical."
}

func (f *Fetch) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"src": stringProp(`File to read, e.g. "/etc/nginx/nginx.conf".`),
	}, "src")
}

func (f *Fetch) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	src, err := stringParam(params, "src", true, "")
	if err != nil {
		return Result{}, err
	}
	return f.Slurp.Run(ctx, map[string]any{"path": src}, dryRun)
}
