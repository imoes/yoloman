package modules

import (
	"context"
	"encoding/json"
	"strings"
)

// StorageFacts gathers a read-only storage overview for the host-management
// page (Block J4d): block devices (lsblk), LVM (pvs/vgs/lvs), and VDO
// (vdostats). It is the native read counterpart to the baked
// community.general storage *configure* modules (lvg/lvol/vdo); ZFS overview
// comes from the baked zfs_facts/zpool_facts modules, so this module does not
// cover ZFS. Every backend degrades independently: a missing binary or a
// failed command yields {available: false, error: ...} for that section
// instead of failing the whole module. Runner is injectable for testing.
type StorageFacts struct {
	Runner CommandRunner
}

// NewStorageFacts returns a StorageFacts module backed by the real binaries.
func NewStorageFacts() *StorageFacts {
	return &StorageFacts{Runner: defaultCommandRunner}
}

func (m *StorageFacts) Name() string { return "storage_facts" }

func (m *StorageFacts) Description() string {
	return "" +
		"Gather a read-only storage overview of the host: block devices (lsblk), LVM physical " +
		"volumes / volume groups / logical volumes (pvs/vgs/lvs), and VDO volumes (vdostats). " +
		"Returns {block_devices, lvm, vdo}, each with an `available` flag that is false (plus an " +
		"`error`) when the underlying tool is absent or fails — so it never crashes on a host " +
		"without LVM/VDO. Read-only: always changed=false. Pairs with the write-gated " +
		"community.general lvg/lvol/vdo modules for management, and with zfs_facts/zpool_facts " +
		"for ZFS (not covered here). Use it as the Storage section of the host-management page " +
		"and as an MCP tool.\n\n" +
		"Cross-tool equivalents: no single Ansible module covers all three; this aggregates what " +
		"`ansible.builtin.setup`'s device facts, community.general.lvg/lvol, and vdostats expose."
}

func (m *StorageFacts) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (m *StorageFacts) Writes() bool { return false }

func (m *StorageFacts) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	data := map[string]any{
		"block_devices": m.blockDevices(ctx),
		"lvm":           m.lvm(ctx),
		"vdo":           m.vdo(ctx),
	}
	return Result{Changed: false, Msg: "gathered storage facts", Data: data}, nil
}

// probe runs a command and classifies the outcome: available is false only
// when the binary could not be started at all (absent); a non-zero exit means
// the tool is present but errored (available stays true, error carries why).
func (m *StorageFacts) probe(ctx context.Context, name string, args ...string) (out []byte, available bool, errMsg string) {
	b, err := m.Runner(ctx, name, args...)
	if err == nil {
		return b, true, ""
	}
	if isExitError(err) {
		return b, true, strings.TrimSpace(err.Error())
	}
	return nil, false, err.Error()
}

// blockDevices parses `lsblk -J -O -b` (JSON, all columns, sizes in bytes so
// the UI can render filesystem usage bars) into its device tree.
func (m *StorageFacts) blockDevices(ctx context.Context) map[string]any {
	out, available, errMsg := m.probe(ctx, "lsblk", "-J", "-O", "-b")
	res := map[string]any{"available": available}
	if !available {
		res["error"] = errMsg
		return res
	}
	var parsed struct {
		Blockdevices []map[string]any `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		res["available"] = false
		res["error"] = "parsing lsblk JSON: " + err.Error()
		return res
	}
	if parsed.Blockdevices == nil {
		parsed.Blockdevices = []map[string]any{}
	}
	res["devices"] = parsed.Blockdevices
	return res
}

// lvm gathers PVs, VGs and LVs via the JSON report format. `available` is keyed
// off vgs (the core LVM query); each list degrades on its own.
func (m *StorageFacts) lvm(ctx context.Context) map[string]any {
	res := map[string]any{}
	vgs, vgAvail, vgErr := m.lvmReport(ctx, "vgs", "vg")
	res["available"] = vgAvail
	if !vgAvail {
		res["error"] = vgErr
		return res
	}
	res["vgs"] = vgs
	pvs, _, _ := m.lvmReport(ctx, "pvs", "pv")
	res["pvs"] = pvs
	lvs, _, _ := m.lvmReport(ctx, "lvs", "lv")
	res["lvs"] = lvs
	return res
}

// lvmReport runs `<tool> --reportformat json` and pulls report[0][key] — the
// list of objects LVM nests under e.g. "vg"/"pv"/"lv".
func (m *StorageFacts) lvmReport(ctx context.Context, tool, key string) ([]map[string]any, bool, string) {
	out, available, errMsg := m.probe(ctx, tool, "--reportformat", "json", "--units", "b", "--nosuffix")
	if !available {
		return nil, false, errMsg
	}
	var parsed struct {
		Report []map[string][]map[string]any `json:"report"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, false, "parsing " + tool + " JSON: " + err.Error()
	}
	items := []map[string]any{}
	if len(parsed.Report) > 0 {
		if list, ok := parsed.Report[0][key]; ok {
			items = list
		}
	}
	return items, true, ""
}

// vdo probes VDO volumes via vdostats. VDO is rarely present; when absent the
// section is simply {available: false}.
func (m *StorageFacts) vdo(ctx context.Context) map[string]any {
	out, available, errMsg := m.probe(ctx, "vdostats", "--verbose")
	res := map[string]any{"available": available}
	if !available {
		res["error"] = errMsg
		return res
	}
	// vdostats output is free-form text; surface the raw non-empty lines so the
	// UI can show it without this module hard-coding a fragile parser.
	lines := []string{}
	for _, l := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	res["raw"] = lines
	return res
}
