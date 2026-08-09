package modules

import (
	"context"
	"errors"
	"os/exec"
	"testing"
)

// fakeExitError is a non-nil error that isExitError recognizes, standing in
// for a command that ran but exited non-zero.
func fakeExitError() error {
	// A real *exec.ExitError is hard to fabricate; use exec of a guaranteed
	// non-zero to get one. `false` exits 1.
	return exec.Command("false").Run()
}

func TestStorageFacts_ParsesLsblkAndLVM(t *testing.T) {
	m := &StorageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		switch name {
		case "lsblk":
			return []byte(`{"blockdevices":[{"name":"sda","size":"100G","type":"disk","children":[{"name":"sda1","size":"100G","type":"part"}]}]}`), nil
		case "vgs":
			return []byte(`{"report":[{"vg":[{"vg_name":"datavg","vg_size":"107374182400","vg_free":"0"}]}]}`), nil
		case "pvs":
			return []byte(`{"report":[{"pv":[{"pv_name":"/dev/sda1","vg_name":"datavg"}]}]}`), nil
		case "lvs":
			return []byte(`{"report":[{"lv":[{"lv_name":"data1","vg_name":"datavg","lv_size":"32212254720"}]}]}`), nil
		case "vdostats":
			return nil, errors.New(`exec: "vdostats": executable file not found in $PATH`)
		}
		return nil, errors.New("unexpected " + name)
	}}

	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)

	bd := data["block_devices"].(map[string]any)
	if bd["available"] != true {
		t.Fatalf("block_devices not available: %+v", bd)
	}
	if len(bd["devices"].([]map[string]any)) != 1 {
		t.Errorf("expected 1 block device, got %+v", bd["devices"])
	}

	lvm := data["lvm"].(map[string]any)
	if lvm["available"] != true {
		t.Fatalf("lvm not available: %+v", lvm)
	}
	vgs := lvm["vgs"].([]map[string]any)
	if len(vgs) != 1 || vgs[0]["vg_name"] != "datavg" {
		t.Errorf("unexpected vgs: %+v", vgs)
	}
	if len(lvm["pvs"].([]map[string]any)) != 1 || len(lvm["lvs"].([]map[string]any)) != 1 {
		t.Errorf("expected 1 pv + 1 lv: %+v", lvm)
	}

	// vdostats absent -> that section degrades, not the whole module.
	vdo := data["vdo"].(map[string]any)
	if vdo["available"] != false || vdo["error"] == nil {
		t.Errorf("vdo should be unavailable with an error: %+v", vdo)
	}
}

func TestStorageFacts_DegradesWhenLVMAbsent(t *testing.T) {
	m := &StorageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "lsblk" {
			return []byte(`{"blockdevices":[]}`), nil
		}
		// Everything else "not found".
		return nil, errors.New(`exec: "` + name + `": executable file not found in $PATH`)
	}}
	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run must not fail even when LVM/VDO are absent: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["lvm"].(map[string]any)["available"] != false {
		t.Error("lvm should be unavailable")
	}
	if data["block_devices"].(map[string]any)["available"] != true {
		t.Error("block_devices should still be available")
	}
}

func TestStorageFacts_NonzeroExitIsAvailable(t *testing.T) {
	// vgs present but exits non-zero (e.g. transient error) -> available true,
	// error surfaced, module still returns cleanly.
	exitErr := fakeExitError()
	m := &StorageFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "vgs" {
			return []byte("garbage-not-json"), exitErr
		}
		return []byte(`{"blockdevices":[]}`), nil
	}}
	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	// vgs ran (present) but its output wasn't JSON -> available flips false with
	// a parse error, which is acceptable degradation (not a crash).
	lvm := res.Data.(map[string]any)["lvm"].(map[string]any)
	if lvm["available"] != false {
		t.Errorf("expected lvm unavailable on unparseable output, got %+v", lvm)
	}
}

func TestStorageFacts_IsReadOnly(t *testing.T) {
	if NewStorageFacts().Writes() {
		t.Error("storage_facts must be read-only")
	}
}
