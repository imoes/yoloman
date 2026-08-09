package modules

import (
	"context"
	"strconv"
	"strings"
)

// VirtFacts detects which local virtualization stack(s) a host runs and lists
// their guests — the read counterpart to the qm/virsh management modules. It
// probes Proxmox VE (the `qm`/`pct` CLIs) and libvirt/KVM (`virsh`), each
// degrading independently: a stack whose CLI is absent reports
// {available:false} instead of failing. This is how "the agent must recognize
// what runs on each virtualization server" is answered. Read-only. Runner is
// injectable for testing.
type VirtFacts struct {
	Runner CommandRunner
}

// NewVirtFacts returns a VirtFacts module backed by the real CLIs.
func NewVirtFacts() *VirtFacts { return &VirtFacts{Runner: defaultCommandRunner} }

func (m *VirtFacts) Name() string { return "virt_facts" }

func (m *VirtFacts) Description() string {
	return "" +
		"Detect the host's local virtualization stack(s) and list their guests: Proxmox VE (via " +
		"the `qm list` / `pct list` CLIs — QEMU VMs and LXC containers) and libvirt/KVM (via " +
		"`virsh list --all` — domains). Returns {proxmox:{available,vms,containers}, libvirt:" +
		"{available,domains}, hypervisors:[...]}, where each stack's `available` is false (with an " +
		"`error`) when its CLI is absent — so it never fails on a non-hypervisor host. Read-only " +
		"(changed=false). Pair with the write-gated `qm` / `virsh` modules to control a guest. Use " +
		"it to answer 'is this a Proxmox node or a KVM host, and what is running on it'.\n\n" +
		"Note: this is LOCAL node management via the on-host CLIs, distinct from the " +
		"community.general.proxmox_* modules which drive a Proxmox cluster remotely over its API."
}

func (m *VirtFacts) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (m *VirtFacts) Writes() bool { return false }

func (m *VirtFacts) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	proxmox := m.proxmox(ctx)
	libvirt := m.libvirt(ctx)

	hypervisors := []string{}
	if proxmox["available"] == true {
		hypervisors = append(hypervisors, "proxmox")
	}
	if libvirt["available"] == true {
		hypervisors = append(hypervisors, "libvirt")
	}

	data := map[string]any{
		"hypervisors": hypervisors,
		"proxmox":     proxmox,
		"libvirt":     libvirt,
	}
	msg := "no local virtualization stack detected"
	if len(hypervisors) > 0 {
		msg = "detected: " + strings.Join(hypervisors, ", ")
	}
	return Result{Changed: false, Msg: msg, Data: data}, nil
}

// probe runs a command; available is false only when the binary is absent
// (couldn't start). A non-zero exit means the CLI is present but errored.
func (m *VirtFacts) probe(ctx context.Context, name string, args ...string) (out []byte, available bool, errMsg string) {
	b, err := m.Runner(ctx, name, args...)
	if err == nil {
		return b, true, ""
	}
	if isExitError(err) {
		return b, true, strings.TrimSpace(err.Error())
	}
	return nil, false, err.Error()
}

// proxmox lists Proxmox VE QEMU VMs (qm list) and LXC containers (pct list).
// availability is keyed off qm (the VM CLI); containers degrade on their own.
func (m *VirtFacts) proxmox(ctx context.Context) map[string]any {
	out, available, errMsg := m.probe(ctx, "qm", "list")
	res := map[string]any{"available": available}
	if !available {
		res["error"] = errMsg
		return res
	}
	res["vms"] = parseQmList(out)
	if pctOut, ok, _ := m.probe(ctx, "pct", "list"); ok {
		res["containers"] = parsePctList(pctOut)
	} else {
		res["containers"] = []map[string]any{}
	}
	return res
}

// libvirt lists libvirt/KVM domains (virsh list --all).
func (m *VirtFacts) libvirt(ctx context.Context) map[string]any {
	out, available, errMsg := m.probe(ctx, "virsh", "list", "--all")
	res := map[string]any{"available": available}
	if !available {
		res["error"] = errMsg
		return res
	}
	res["domains"] = parseVirshList(out)
	return res
}

// parseQmList parses `qm list`:
//
//	VMID NAME       STATUS   MEM(MB)  BOOTDISK(GB)  PID
//	 100 vm-one     running  2048     32.00         1234
func parseQmList(out []byte) []map[string]any {
	vms := []map[string]any{}
	for i, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		if i == 0 && (f[0] == "VMID" || strings.EqualFold(f[0], "vmid")) {
			continue // header
		}
		if _, err := strconv.Atoi(f[0]); err != nil {
			continue
		}
		vm := map[string]any{"vmid": f[0], "name": f[1], "status": f[2]}
		if len(f) >= 4 {
			vm["mem_mb"] = f[3]
		}
		if len(f) >= 6 {
			vm["pid"] = f[5]
		}
		vms = append(vms, vm)
	}
	return vms
}

// parsePctList parses `pct list`:
//
//	VMID       Status     Lock         Name
//	105        running                 ct-one
func parsePctList(out []byte) []map[string]any {
	cts := []map[string]any{}
	for i, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		if i == 0 && strings.EqualFold(f[0], "vmid") {
			continue
		}
		if _, err := strconv.Atoi(f[0]); err != nil {
			continue
		}
		ct := map[string]any{"vmid": f[0], "status": f[1]}
		ct["name"] = f[len(f)-1] // Name is the last column (Lock may be empty)
		cts = append(cts, ct)
	}
	return cts
}

// parseVirshList parses `virsh list --all`:
//
//	 Id   Name      State
//	----------------------------
//	 1    vm-one    running
//	 -    vm-two    shut off
func parseVirshList(out []byte) []map[string]any {
	domains := []map[string]any{}
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "----") {
			continue
		}
		f := strings.Fields(trimmed)
		if len(f) < 3 {
			continue
		}
		if f[0] == "Id" && f[1] == "Name" {
			continue // header
		}
		domains = append(domains, map[string]any{
			"id":    f[0],
			"name":  f[1],
			"state": strings.Join(f[2:], " "), // e.g. "shut off"
		})
	}
	return domains
}
