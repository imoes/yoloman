package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"

	"github.com/mutkluge/agentic-mcp/internal/server"
	"github.com/mutkluge/agentic-mcp/internal/starmodules"
	"github.com/mutkluge/agentic-mcp/internal/starmodules/embedded"
)

// runModuleCLI runs ONE module locally from the command line — the offline counterpart to the agent's
// REST/MCP module dispatch. It loads the SAME library the running agent has: the native Go modules, the
// embedded curated Starlark set (yoloman.network_interface, storage, …), and — with --modules-dir — the
// discovered collection modules (ansible.builtin / community.general / posix / …, ~700 of them). So the
// bare-metal provisioner can drive ANY module inside a freshly restored root's chroot, e.g.
//
//	chroot /mnt/target agentic-mcpd run-module community.general.parted --json '{…}'
//	chroot /mnt/target agentic-mcpd run-module yoloman.network_interface --json '{"apply":false,…}'
//
// instead of reinventing partitioning / lvm / filesystem / network / hostname as bespoke shell. Pass
// "apply": false (where a module supports it, e.g. network) so it only writes config into the
// not-yet-running root; the restored machine applies it on its own boot.
func runModuleCLI(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd run-module", flag.ContinueOnError)
	jsonParams := fs.String("json", "{}", "module params as JSON")
	modulesDir := fs.String("modules-dir", "", "also load discovered modules from this dir (native + embedded always load)")
	dryRun := fs.Bool("dry-run", false, "check mode: report what would change without changing it")
	list := fs.Bool("list", false, "list available module names and exit")
	// The module name is the first positional, but callers (and our own docs + the
	// offline provisioner) write `run-module <module> --json '{…}'` with the flags
	// AFTER it. Go's flag package stops at the first positional, so a single
	// fs.Parse(args) would leave those trailing flags unparsed — every module would
	// then run with empty params (and --modules-dir would be ignored). Parse once to
	// reach the module name, then parse the flags that followed it, so flag order
	// (before or after the name) no longer matters — and both passes complete before
	// we load modules, so a trailing --modules-dir is still honoured.
	if err := fs.Parse(args); err != nil {
		return err
	}
	var moduleName string
	if rest := fs.Args(); len(rest) >= 1 {
		moduleName = rest[0]
		if err := fs.Parse(rest[1:]); err != nil {
			return err
		}
	}

	reg := server.NewDefaultModuleRegistry() // native Go modules
	if embFS, err := embedded.FS(); err == nil {
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

	if *list {
		for _, m := range reg.All() {
			fmt.Println(m.Name())
		}
		return nil
	}
	if moduleName == "" {
		return fmt.Errorf("usage: agentic-mcpd run-module <module> [--json '{…}'] [--modules-dir DIR] [--dry-run] | --list")
	}
	var params map[string]any
	if err := json.Unmarshal([]byte(*jsonParams), &params); err != nil {
		return fmt.Errorf("--json: %w", err)
	}
	m, ok := reg.Get(moduleName)
	if !ok {
		return fmt.Errorf("module %q not found (try --list, or --modules-dir to load discovered modules)", moduleName)
	}
	res, err := m.Run(context.Background(), params, *dryRun)
	if err != nil {
		return err
	}
	out, _ := json.Marshal(map[string]any{"changed": res.Changed, "msg": res.Msg, "data": res.Data})
	fmt.Println(string(out))
	return nil
}
