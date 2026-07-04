package modules

// Raw is a thin alias for Command under Ansible's bootstrap-execution
// module name. Real Ansible's raw module exists to run a command over SSH
// on a target that doesn't have Python installed yet, bypassing the normal
// module subsystem entirely — a bootstrapping mechanism for otherwise-
// unmanageable hosts. This agent has no such problem: it *is* a single
// compiled Go binary with no separate module-transfer step, so there is no
// "before Python is installed" state to bootstrap out of. Raw and command
// are therefore functionally identical here, the same reasoning that makes
// fetch an alias of slurp and script an alias of command.
type Raw struct{ *Command }

// NewRaw returns a Raw module (a thin alias of Command).
func NewRaw() *Raw { return &Raw{Command: NewCommand()} }

func (r *Raw) Name() string { return "raw" }

func (r *Raw) Description() string {
	return "" +
		"Alias of the command module under Ansible's bootstrap-execution module name. Real " +
		"Ansible's raw module runs a command over SSH on a target with no Python installed yet, " +
		"bypassing the normal module subsystem — a bootstrapping mechanism for otherwise-" +
		"unmanageable hosts. This agent has no such problem: it is a single compiled Go binary " +
		"with no separate module-transfer step, so raw and command behave identically here. See " +
		"the command module's description for full parameter and cross-tool details."
}
