package modules

import (
	"context"
	"errors"
	"testing"
)

func TestVirtFacts_ParsesProxmoxAndLibvirt(t *testing.T) {
	qmList := "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n" +
		"       100 web01                running    2048              32.00 1234\n" +
		"       101 db01                 stopped    4096              64.00 0\n"
	pctList := "VMID       Status     Lock         Name\n" +
		"105        running                 ct-one\n"
	virshList := " Id   Name      State\n" +
		"----------------------------\n" +
		" 1    kvm-one   running\n" +
		" -    kvm-two   shut off\n"

	m := &VirtFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "qm" && args[0] == "list":
			return []byte(qmList), nil
		case name == "pct" && args[0] == "list":
			return []byte(pctList), nil
		case name == "virsh":
			return []byte(virshList), nil
		}
		return nil, errors.New("unexpected " + name)
	}}

	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	hyps := data["hypervisors"].([]string)
	if len(hyps) != 2 {
		t.Errorf("expected proxmox+libvirt, got %v", hyps)
	}

	prox := data["proxmox"].(map[string]any)
	vms := prox["vms"].([]map[string]any)
	if len(vms) != 2 || vms[0]["vmid"] != "100" || vms[0]["name"] != "web01" || vms[0]["status"] != "running" {
		t.Errorf("unexpected qm vms: %+v", vms)
	}
	cts := prox["containers"].([]map[string]any)
	if len(cts) != 1 || cts[0]["name"] != "ct-one" {
		t.Errorf("unexpected pct containers: %+v", cts)
	}

	lv := data["libvirt"].(map[string]any)
	doms := lv["domains"].([]map[string]any)
	if len(doms) != 2 || doms[1]["state"] != "shut off" {
		t.Errorf("unexpected virsh domains: %+v", doms)
	}
}

func TestVirtFacts_DegradesOnNonHypervisor(t *testing.T) {
	// A plain host: neither qm nor virsh present.
	m := &VirtFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New(`exec: "` + name + `": executable file not found in $PATH`)
	}}
	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run must not fail on a non-hypervisor: %v", err)
	}
	data := res.Data.(map[string]any)
	if len(data["hypervisors"].([]string)) != 0 {
		t.Error("expected no hypervisors")
	}
	if data["proxmox"].(map[string]any)["available"] != false || data["libvirt"].(map[string]any)["available"] != false {
		t.Error("both stacks should be unavailable")
	}
}

func TestVirtFacts_IsReadOnly(t *testing.T) {
	if NewVirtFacts().Writes() {
		t.Error("virt_facts must be read-only")
	}
}
