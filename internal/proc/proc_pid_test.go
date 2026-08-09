package proc

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestParsePidStat(t *testing.T) {
	// A normal process line (fields per proc(5)); comm is "bash".
	line := "1234 (bash) S 1000 1234 1234 34816 1234 4194304 " +
		"100 200 0 0 " + // minflt cminflt majflt cmajflt (fields 10-13)
		"111 222 0 0 " + // utime stime cutime cstime (fields 14-17)
		"20 0 3 0 " + // priority nice num_threads itrealvalue (fields 18-21)
		"9876543 " + // starttime (field 22)
		"12345678 4096 " // vsize rss-pages (fields 23-24)
	ps, err := ParsePidStat(strings.NewReader(line))
	if err != nil {
		t.Fatalf("ParsePidStat: %v", err)
	}
	if ps.PID != 1234 {
		t.Errorf("PID = %d, want 1234", ps.PID)
	}
	if ps.Comm != "bash" {
		t.Errorf("Comm = %q, want bash", ps.Comm)
	}
	if ps.State != "S" {
		t.Errorf("State = %q, want S", ps.State)
	}
	if ps.PPID != 1000 {
		t.Errorf("PPID = %d, want 1000", ps.PPID)
	}
	if ps.Utime != 111 || ps.Stime != 222 {
		t.Errorf("Utime/Stime = %d/%d, want 111/222", ps.Utime, ps.Stime)
	}
	if ps.CPUTicks() != 333 {
		t.Errorf("CPUTicks = %d, want 333", ps.CPUTicks())
	}
	if ps.NumThreads != 3 {
		t.Errorf("NumThreads = %d, want 3", ps.NumThreads)
	}
	if ps.Starttime != 9876543 {
		t.Errorf("Starttime = %d, want 9876543", ps.Starttime)
	}
	if ps.RSSPages != 4096 {
		t.Errorf("RSSPages = %d, want 4096", ps.RSSPages)
	}
}

func TestParsePidStatCommWithSpacesAndParens(t *testing.T) {
	// Firefox's content process comm contains a space; a naive whitespace
	// split would mis-align every subsequent field. The closing paren must be
	// matched as the *last* ')'.
	line := "42 (Web Content) R 40 42 42 0 -1 4194560 " +
		"5 6 7 8 " +
		"500 600 0 0 " +
		"20 0 25 0 " +
		"555 " +
		"999 128"
	ps, err := ParsePidStat(strings.NewReader(line))
	if err != nil {
		t.Fatalf("ParsePidStat: %v", err)
	}
	if ps.Comm != "Web Content" {
		t.Errorf("Comm = %q, want %q", ps.Comm, "Web Content")
	}
	if ps.State != "R" {
		t.Errorf("State = %q, want R", ps.State)
	}
	if ps.Utime != 500 || ps.Stime != 600 {
		t.Errorf("Utime/Stime = %d/%d, want 500/600", ps.Utime, ps.Stime)
	}
	if ps.NumThreads != 25 {
		t.Errorf("NumThreads = %d, want 25", ps.NumThreads)
	}
}

func TestParseStatCPU(t *testing.T) {
	stat := "cpu  100 20 30 400 50 0 10 0 0 0\n" +
		"cpu0 50 10 15 200 25 0 5 0 0 0\n" +
		"cpu1 50 10 15 200 25 0 5 0 0 0\n" +
		"intr 12345\nctxt 67890\n"
	total, numCPU, err := ParseStatCPU(strings.NewReader(stat))
	if err != nil {
		t.Fatalf("ParseStatCPU: %v", err)
	}
	if total != 610 { // 100+20+30+400+50+0+10
		t.Errorf("total = %d, want 610", total)
	}
	if numCPU != 2 {
		t.Errorf("numCPU = %d, want 2", numCPU)
	}
}

func TestParsePidStatus(t *testing.T) {
	status := "Name:\tsshd\nState:\tS (sleeping)\n" +
		"Uid:\t0\t0\t0\t0\nVmRSS:\t  7532 kB\nThreads:\t1\n"
	st, err := ParsePidStatus(strings.NewReader(status))
	if err != nil {
		t.Fatalf("ParsePidStatus: %v", err)
	}
	if st.UID != 0 {
		t.Errorf("UID = %d, want 0", st.UID)
	}
	if st.VmRSSKiB != 7532 {
		t.Errorf("VmRSSKiB = %d, want 7532", st.VmRSSKiB)
	}
}

func TestParseCmdline(t *testing.T) {
	cmd, err := ParseCmdline(strings.NewReader("nginx\x00-g\x00daemon off;\x00"))
	if err != nil {
		t.Fatalf("ParseCmdline: %v", err)
	}
	if cmd != "nginx -g daemon off;" {
		t.Errorf("cmd = %q, want %q", cmd, "nginx -g daemon off;")
	}
	// Kernel thread: empty cmdline.
	empty, _ := ParseCmdline(strings.NewReader("\x00"))
	if empty != "" {
		t.Errorf("empty cmdline = %q, want empty", empty)
	}
}

func TestCPUPercent(t *testing.T) {
	// 50 proc ticks out of 1000 total, on 4 cores → 50/1000 * 4 * 100 = 20%.
	if got := cpuPercent(50, 1000, 4); got != 20 {
		t.Errorf("cpuPercent = %v, want 20", got)
	}
	// Zero total delta must not divide by zero.
	if got := cpuPercent(10, 0, 4); got != 0 {
		t.Errorf("cpuPercent with zero total = %v, want 0", got)
	}
}

func TestSampleProcessesAgainstRealProc(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc on this platform")
	}
	procs, err := SampleProcesses("/proc", 50*time.Millisecond)
	if err != nil {
		t.Fatalf("SampleProcesses: %v", err)
	}
	if len(procs) == 0 {
		t.Fatal("expected at least this test process to be listed")
	}
	// The list must be CPU-descending (default "hungriest first").
	for i := 1; i < len(procs); i++ {
		if procs[i-1].CPUPercent < procs[i].CPUPercent {
			t.Fatalf("not sorted CPU-desc at %d: %v < %v", i, procs[i-1].CPUPercent, procs[i].CPUPercent)
		}
	}
	// Find our own PID and sanity-check its fields.
	me := os.Getpid()
	var found bool
	for _, p := range procs {
		if p.PID == me {
			found = true
			if p.Command == "" {
				t.Errorf("own process has empty command")
			}
			if p.NumThreads < 1 {
				t.Errorf("own process NumThreads = %d, want >= 1", p.NumThreads)
			}
		}
	}
	if !found {
		t.Errorf("test process PID %d not found in list", me)
	}
}
