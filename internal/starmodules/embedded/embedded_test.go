package embedded

import (
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/starmodules"
)

// The baked set must load through the shared loader and expose each module by
// its real fqcn, so it registers and dispatches like a native module. This is
// the go:embed round-trip: files -> embed.FS -> LoadFS -> StarModule.
func TestEmbeddedModulesLoad(t *testing.T) {
	fsys, err := FS()
	if err != nil {
		t.Fatalf("FS(): %v", err)
	}
	mods, warnings, err := starmodules.LoadFS(fsys, true /* write gate open, so write modules load */)
	if err != nil {
		t.Fatalf("LoadFS: %v", err)
	}
	for _, w := range warnings {
		t.Errorf("baked module failed to load (must be runnable before baking): %s", w)
	}
	if len(mods) == 0 {
		t.Fatal("no embedded modules loaded")
	}
	byName := map[string]bool{}
	for _, m := range mods {
		byName[m.Name()] = true
	}
	// The baked storage stack (LVM/VDO/ZFS): all lint-clean + contract-correct
	// (verified with the shim-enabled validator); the facts + vdo/zfs paths are
	// stub_ok=true, the command-driven configure modules are validated live on
	// a host with the actual tooling.
	for _, want := range []string{
		"yoloman.network_interface",
		"community.general.vdo",
		"community.general.zfs",
		"community.general.zfs_facts",
		"community.general.zpool_facts",
		"community.general.lvg",
		"community.general.lvol",
		"community.general.filesystem",
	} {
		if !byName[want] {
			t.Errorf("expected %s among baked modules, got %v", want, byName)
		}
	}
}
