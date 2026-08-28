package modules

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// waitJob polls status until the job leaves "running" (or the deadline hits).
func waitJob(t *testing.T, m *DiskMove, id string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		res, err := m.Run(context.Background(), map[string]any{"action": "status", "job_id": id}, false)
		if err != nil {
			t.Fatalf("status: %v", err)
		}
		data := res.Data.(map[string]any)
		if data["state"] != "running" {
			return data
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("job did not finish in time")
	return nil
}

// A move to a LOWER offset (left) can be copied forwards.
func TestDiskMoveForwards(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disk.img")
	data := make([]byte, 64*1024)
	for i := range data {
		data[i] = byte(i % 251)
	}
	payload := data[32*1024 : 40*1024] // 8 KiB at offset 32 KiB
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	want := append([]byte(nil), payload...)

	m := NewDiskMove()
	res, err := m.Run(context.Background(), map[string]any{
		"action": "start", "device": path,
		"src_offset": 32 * 1024, "dst_offset": 8 * 1024, "length": 8 * 1024, "block_size": 4096,
	}, false)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	started := res.Data.(map[string]any)
	if started["backwards"].(bool) {
		t.Fatalf("a left move must copy forwards, got backwards")
	}
	fin := waitJob(t, m, started["job_id"].(string))
	if fin["state"] != "done" {
		t.Fatalf("state=%v err=%v", fin["state"], fin["error"])
	}
	if got := fin["done_bytes"]; got != int64(8*1024) {
		t.Fatalf("done_bytes=%v", got)
	}
	out, _ := os.ReadFile(path)
	if !bytes.Equal(out[8*1024:16*1024], want) {
		t.Fatal("destination does not hold the moved bytes")
	}
}

// A move to a HIGHER offset with OVERLAPPING ranges is the dangerous case: a
// forward copy would clobber bytes it has not read yet. It must copy backwards
// and the result must still be the original payload (GParted's CopyBlocks rule).
func TestDiskMoveBackwardsOverlapping(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disk.img")
	total := 64 * 1024
	data := make([]byte, total)
	for i := range data {
		data[i] = byte(i % 251)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	// 16 KiB at offset 8 KiB moved to offset 16 KiB → the ranges overlap by 8 KiB
	want := append([]byte(nil), data[8*1024:24*1024]...)

	m := NewDiskMove()
	res, err := m.Run(context.Background(), map[string]any{
		"action": "start", "device": path,
		"src_offset": 8 * 1024, "dst_offset": 16 * 1024, "length": 16 * 1024, "block_size": 4096,
	}, false)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	started := res.Data.(map[string]any)
	if !started["backwards"].(bool) {
		t.Fatal("an overlapping right move must copy backwards")
	}
	fin := waitJob(t, m, started["job_id"].(string))
	if fin["state"] != "done" {
		t.Fatalf("state=%v err=%v", fin["state"], fin["error"])
	}
	out, _ := os.ReadFile(path)
	if !bytes.Equal(out[16*1024:32*1024], want) {
		t.Fatal("overlapping backwards copy corrupted the payload")
	}
}

func TestDiskMoveValidationAndDryRun(t *testing.T) {
	m := NewDiskMove()
	if _, err := m.Run(context.Background(), map[string]any{"action": "bogus"}, false); err == nil {
		t.Fatal("expected an error for an unknown action")
	}
	if _, err := m.Run(context.Background(), map[string]any{
		"action": "start", "device": "/dev/null", "src_offset": 0, "dst_offset": 1,
	}, false); err == nil {
		t.Fatal("expected an error when length is missing")
	}
	// identical offsets are a no-op, not an error
	res, err := m.Run(context.Background(), map[string]any{
		"action": "start", "device": "/dev/null", "src_offset": 4096, "dst_offset": 4096, "length": 10,
	}, false)
	if err != nil || res.Changed {
		t.Fatalf("same offset should be a no-op, got changed=%v err=%v", res.Changed, err)
	}
	// dry run must not touch anything and must report the direction
	res, err = m.Run(context.Background(), map[string]any{
		"action": "start", "device": "/dev/null", "src_offset": 0, "dst_offset": 4096, "length": 4096,
	}, true)
	if err != nil {
		t.Fatal(err)
	}
	if res.Changed {
		t.Fatal("dry run must not report a change")
	}
	if !bytes.Contains([]byte(res.Msg), []byte("backwards")) {
		t.Fatalf("dry run should name the direction, got %q", res.Msg)
	}
}
