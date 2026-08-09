package modules

import "context"

// Virsh exposes the FULL libvirt `virsh` CLI as one module: any subcommand
// (start/shutdown/destroy/reboot/suspend/resume, snapshot-create-as/
// snapshot-delete/snapshot-revert/snapshot-list, migrate, define/undefine,
// attach-disk/detach-disk, setvcpus/setmem, dumpxml, dominfo, domstate,
// list, …) via command + args — the whole virsh surface in one tool. Read
// subcommands run even in check_mode; mutating ones are write-gated and
// skipped under dry_run. Runner is injectable.
type Virsh struct {
	Runner CommandRunner
}

// NewVirsh returns a Virsh module backed by the real virsh CLI.
func NewVirsh() *Virsh { return &Virsh{Runner: defaultCommandRunner} }

func (m *Virsh) Name() string { return "virsh" }

// virshReadOnly are the virsh subcommands that only read state.
var virshReadOnly = map[string]bool{
	"list": true, "dominfo": true, "domstate": true, "domblklist": true,
	"domiflist": true, "snapshot-list": true, "dumpxml": true, "capabilities": true,
	"nodeinfo": true, "version": true, "domuuid": true, "domid": true,
	"domname": true, "vcpuinfo": true, "domstats": true, "domifaddr": true,
	"pool-list": true, "vol-list": true, "net-list": true,
}

func (m *Virsh) Description() string {
	return "" +
		"Run any libvirt `virsh` subcommand via the local CLI — the full virsh surface in one " +
		"tool. Set command to the subcommand and args to the rest of the command line, e.g. " +
		"command=\"start\" args=[\"web01\"], command=\"snapshot-create-as\" args=[\"web01\",\"snap1\"], " +
		"command=\"migrate\" args=[\"--live\",\"web01\",\"qemu+ssh://node2/system\"], or " +
		"command=\"setmem\" args=[\"web01\",\"2G\",\"--config\"]. Power: start, shutdown, destroy, " +
		"reboot, suspend, resume. Snapshots: snapshot-create-as, snapshot-delete, " +
		"snapshot-revert, snapshot-list. Also migrate, define/undefine, attach-disk/detach-disk, " +
		"setvcpus/setmem, dumpxml, dominfo, domstate, list. Read subcommands run even in " +
		"check_mode (changed=false); every other subcommand is mutating — write-gated, skipped " +
		"under dry_run=true, changed=true. Returns {rc, stdout, stderr}. Idempotency is the " +
		"caller's responsibility. List domains/detect the hypervisor with virt_facts."
}

func (m *Virsh) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"command": stringProp("The virsh subcommand, e.g. \"start\", \"snapshot-create-as\", \"migrate\", \"setmem\", \"dominfo\", \"list\"."),
		"args": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "string"},
			"description": "Positional arguments and flags after the subcommand, e.g. [\"--live\",\"web01\",\"qemu+ssh://node2/system\"].",
		},
		"dry_run": boolProp("When true, mutating subcommands are reported but not executed (check_mode). Read subcommands still run.", false),
	}, "command")
}

func (m *Virsh) Writes() bool { return true }

func (m *Virsh) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	return dispatchCLI(ctx, m.Runner, "virsh", virshReadOnly, params, dryRunArg)
}
