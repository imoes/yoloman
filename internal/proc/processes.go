package proc

import (
	"bytes"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Process is one row of the eBPF-enrichable process list (Block J1): the
// per-PID view /proc offers, with a CPU% computed over a short sampling
// window. Enrichment fields (container id, connections) are added by the
// server layer, which owns the eBPF collector — this package stays free of
// that dependency.
type Process struct {
	PID        int     `json:"pid"`
	PPID       int     `json:"ppid"`
	User       string  `json:"user"`
	UID        int     `json:"uid"`
	Comm       string  `json:"comm"`
	Command    string  `json:"command"`
	State      string  `json:"state"`
	CPUPercent float64 `json:"cpu_percent"`
	RSSKiB     int64   `json:"rss_kib"`
	NumThreads int     `json:"num_threads"`
}

// cpuPercent scales a process' CPU-tick delta against the system-wide jiffy
// delta to a "100% == one core" reading (top's convention), so a busy
// multi-threaded process can legitimately exceed 100%.
func cpuPercent(procDelta, totalDelta uint64, numCPU int) float64 {
	if totalDelta == 0 {
		return 0
	}
	if numCPU < 1 {
		numCPU = 1
	}
	return 100 * float64(procDelta) / float64(totalDelta) * float64(numCPU)
}

// listPIDs returns the numeric entries of root (i.e. /proc), one per live
// process. Non-numeric entries (self, net, meminfo, …) are skipped.
func listPIDs(root string) ([]int, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

// readPidStat reads and parses /proc/<pid>/stat, tolerating a process that
// exited between enumeration and read (returns ok=false).
func readPidStat(root string, pid int) (PidStat, bool) {
	data, err := SafeRead(root, filepath.Join(strconv.Itoa(pid), "stat"), 0)
	if err != nil {
		return PidStat{}, false
	}
	ps, err := ParsePidStat(bytes.NewReader(data))
	if err != nil {
		return PidStat{}, false
	}
	return ps, true
}

func readStatCPU(root string) (total uint64, numCPU int, err error) {
	data, err := SafeRead(root, "stat", 0)
	if err != nil {
		return 0, 0, err
	}
	return ParseStatCPU(bytes.NewReader(data))
}

// SampleProcesses enumerates every process under root (typically "/proc"),
// computing each one's CPU% over the given window by sampling CPU ticks at
// the start and end. It also reads memory, owner and command line for the
// processes that survive the window. Processes that appear or vanish during
// the window are handled gracefully (a newcomer simply gets 0% this round).
func SampleProcesses(root string, window time.Duration) ([]Process, error) {
	total1, _, err := readStatCPU(root)
	if err != nil {
		return nil, err
	}
	pids, err := listPIDs(root)
	if err != nil {
		return nil, err
	}
	firstTicks := make(map[int]uint64, len(pids))
	for _, pid := range pids {
		if ps, ok := readPidStat(root, pid); ok {
			firstTicks[pid] = ps.CPUTicks()
		}
	}

	time.Sleep(window)

	total2, numCPU, err := readStatCPU(root)
	if err != nil {
		return nil, err
	}
	dtotal := total2 - total1

	pids, err = listPIDs(root)
	if err != nil {
		return nil, err
	}

	userCache := map[int]string{}
	resolveUser := func(uid int) string {
		if uid < 0 {
			return ""
		}
		if name, ok := userCache[uid]; ok {
			return name
		}
		name := strconv.Itoa(uid)
		if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
			name = u.Username
		}
		userCache[uid] = name
		return name
	}

	procs := make([]Process, 0, len(pids))
	for _, pid := range pids {
		ps, ok := readPidStat(root, pid)
		if !ok {
			continue
		}
		p := Process{
			PID:        ps.PID,
			PPID:       ps.PPID,
			Comm:       ps.Comm,
			State:      ps.State,
			NumThreads: ps.NumThreads,
			UID:        -1,
		}
		if prev, seen := firstTicks[pid]; seen {
			p.CPUPercent = cpuPercent(ps.CPUTicks()-prev, dtotal, numCPU)
		}

		// Memory + owner from status (best-effort; kernel threads have no VmRSS).
		if data, err := SafeRead(root, filepath.Join(strconv.Itoa(pid), "status"), 0); err == nil {
			if stt, err := ParsePidStatus(bytes.NewReader(data)); err == nil {
				p.RSSKiB = stt.VmRSSKiB
				p.UID = stt.UID
				p.User = resolveUser(stt.UID)
			}
		}

		// Full command line, falling back to the bracketed comm for threads.
		if data, err := SafeRead(root, filepath.Join(strconv.Itoa(pid), "cmdline"), 0); err == nil {
			if cmd, _ := ParseCmdline(bytes.NewReader(data)); cmd != "" {
				p.Command = cmd
			}
		}
		if p.Command == "" {
			p.Command = "[" + ps.Comm + "]"
		}

		procs = append(procs, p)
	}

	// Default ordering: hungriest first (CPU desc, then RSS desc), the
	// "Ressourcenfresser identifizieren" default the process table wants.
	sort.Slice(procs, func(i, j int) bool {
		if procs[i].CPUPercent != procs[j].CPUPercent {
			return procs[i].CPUPercent > procs[j].CPUPercent
		}
		return procs[i].RSSKiB > procs[j].RSSKiB
	})
	return procs, nil
}
