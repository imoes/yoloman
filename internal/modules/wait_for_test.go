package modules

import (
	"context"
	"fmt"
	"net"
	"os"
	"testing"
	"time"
)

func noopSleep(time.Duration) {}

func TestWaitFor_StartedSucceedsImmediatelyWhenPortOpen(t *testing.T) {
	w := &WaitFor{
		Dial:  func(network, addr string, timeout time.Duration) error { return nil },
		Sleep: noopSleep,
	}
	res, err := w.Run(context.Background(), map[string]any{"port": "8080"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("wait_for never reports changed=true")
	}
}

func TestWaitFor_StartedRetriesUntilPortOpens(t *testing.T) {
	attempts := 0
	w := &WaitFor{
		Dial: func(network, addr string, timeout time.Duration) error {
			attempts++
			if attempts < 3 {
				return fmt.Errorf("connection refused")
			}
			return nil
		},
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"port": "8080", "timeout": 10}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if attempts != 3 {
		t.Errorf("expected 3 dial attempts, got %d", attempts)
	}
}

func TestWaitFor_StartedTimesOutWhenPortNeverOpens(t *testing.T) {
	w := &WaitFor{
		Dial:  func(network, addr string, timeout time.Duration) error { return fmt.Errorf("connection refused") },
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"port": "8080", "timeout": 2, "sleep": 1}, false)
	if err == nil {
		t.Fatal("expected a timeout error when the port never opens")
	}
}

func TestWaitFor_StoppedSucceedsWhenPortClosed(t *testing.T) {
	w := &WaitFor{
		Dial:  func(network, addr string, timeout time.Duration) error { return fmt.Errorf("connection refused") },
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"port": "8080", "state": "stopped"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestWaitFor_PresentSucceedsWhenFileExists(t *testing.T) {
	w := &WaitFor{
		Stat:  func(path string) error { return nil },
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"path": "/tmp/x", "state": "present"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestWaitFor_AbsentSucceedsWhenFileMissing(t *testing.T) {
	w := &WaitFor{
		Stat:  func(path string) error { return os.ErrNotExist },
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"path": "/tmp/x", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestWaitFor_BothPortAndPathRejected(t *testing.T) {
	w := NewWaitFor()
	_, err := w.Run(context.Background(), map[string]any{"port": "80", "path": "/tmp/x"}, false)
	if err == nil {
		t.Fatal("expected error when both port and path are given")
	}
}

func TestWaitFor_NeitherPortNorPathRejected(t *testing.T) {
	w := NewWaitFor()
	_, err := w.Run(context.Background(), map[string]any{}, false)
	if err == nil {
		t.Fatal("expected error when neither port nor path is given")
	}
}

func TestWaitFor_InvalidState(t *testing.T) {
	w := NewWaitFor()
	_, err := w.Run(context.Background(), map[string]any{"port": "80", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestWaitFor_StateRequiresMatchingParam(t *testing.T) {
	w := NewWaitFor()
	_, err := w.Run(context.Background(), map[string]any{"path": "/tmp/x", "state": "started"}, false)
	if err == nil {
		t.Fatal("expected error when state=started is given path instead of port")
	}
}

func TestWaitFor_DryRunDoesNotBlock(t *testing.T) {
	called := false
	w := &WaitFor{
		Dial:  func(network, addr string, timeout time.Duration) error { called = true; return fmt.Errorf("x") },
		Sleep: noopSleep,
	}
	_, err := w.Run(context.Background(), map[string]any{"port": "80", "dry_run": true}, true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if called {
		t.Error("expected dry_run to never dial")
	}
}

// TestWaitFor_RealPortDetection exercises the module against a real TCP
// listener (not a fake Dial), proving the actual net.DialTimeout path
// correctly detects both an open and a closed port.
func TestWaitFor_RealPortDetection(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("starting listener: %v", err)
	}
	addr := ln.Addr().(*net.TCPAddr)
	host := addr.IP.String()
	port := fmt.Sprintf("%d", addr.Port)

	w := NewWaitFor()
	w.Sleep = noopSleep
	if _, err := w.Run(context.Background(), map[string]any{"host": host, "port": port, "timeout": 5}, false); err != nil {
		t.Fatalf("expected state=started to succeed against a real open port: %v", err)
	}

	ln.Close()
	if _, err := w.Run(context.Background(), map[string]any{"host": host, "port": port, "state": "stopped", "timeout": 5}, false); err != nil {
		t.Fatalf("expected state=stopped to succeed against a real closed port: %v", err)
	}
}
