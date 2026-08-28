package modules

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Swap manages swap AREAS — a swap file or a swap partition — and reads the active ones.
//
// Nothing covered this before: storage_facts reports block devices, LVM and VDO but not swap, and
// the fstab codec can write a swap LINE without any of the steps that make it usable (create the
// file, mkswap, swapon). So "add 2G of swap" was three shell commands and a config edit with no
// observation of the result.
//
// Deliberately NOT touching /etc/fstab. Persistence is one line in a file the config module's
// fstab codec already owns, and two writers for one file is how a config ends up with duplicate
// entries nobody can explain. This module owns the RUNTIME area; the caller pairs it with an fstab
// entry when the swap should survive a reboot, and the two steps stay separately visible.
//
// Swappiness (vm.swappiness) is also out of scope on purpose: it is a kernel tunable, not a swap
// area, and it wants a general `sysctl` module rather than being smuggled in here under a name
// that would then mean two things.
type Swap struct {
	LookPath func(string) (string, error)
	Runner   CommandRunner
}

// NewSwap returns a Swap module backed by the real exec.LookPath and command runner.
func NewSwap() *Swap { return &Swap{LookPath: exec.LookPath, Runner: defaultCommandRunner} }

func (s *Swap) Name() string { return "swap" }

func (s *Swap) Description() string {
	return "" +
		"Read or manage swap areas (swap files and swap partitions). With no `path`: lists the " +
		"ACTIVE areas from /proc/swaps — name, type, size and used bytes, priority. With `path` " +
		"and state=present: creates the file if `size` is given and it is missing, runs mkswap if " +
		"the area is not formatted yet, then swapon — each step skipped when already done, so it " +
		"is idempotent. state=absent runs swapoff, and removes the file only if `remove_file` is " +
		"set (never a partition).\n\n" +
		"It does NOT edit /etc/fstab: that line belongs to the fstab codec (`config` with " +
		"format=fstab), and two writers for one file produce duplicate entries. Pair the two when " +
		"the swap should survive a reboot.\n\n" +
		"Refuses to mkswap a block device that already carries a filesystem unless `force` is set " +
		"— mkswap on a mounted-elsewhere disk destroys it.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: no core module (community.general.filesystem + shell swapon).\n" +
		"- Shell: swapon --show / mkswap / swapon / swapoff."
}

func (s *Swap) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path": stringProp("Swap file or partition, e.g. /swapfile or /dev/sdb2. Omit to read the active areas."),
		"state": stringEnumProp(
			"present = formatted and active; absent = swapped off. Default present when `path` is given.",
			"present", "absent"),
		"size": stringProp(
			"Size for a swap FILE that does not exist yet, e.g. \"2G\" or \"512M\". Ignored for a " +
				"partition and for a file that already exists — this module never resizes an area in " +
				"place, because that means swapoff first and dropping pages of live memory."),
		"priority": map[string]any{
			"type":        "integer",
			"description": "swapon priority (-1..32767). Higher is used first. Omitted = kernel default.",
		},
		"remove_file": boolProp(
			"With state=absent, also delete the swap FILE after swapoff. Never deletes a partition. "+
				"Default false: swapping off is reversible, deleting is not.", false),
		"force": boolProp(
			"Allow mkswap on a block device that already carries a filesystem. Default false.", false),
	})
}

func (s *Swap) Writes() bool { return true }

func (s *Swap) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	path, err := stringParam(params, "path", false, "")
	if err != nil {
		return Result{}, fmt.Errorf("swap: %w", err)
	}
	areas, aerr := readProcSwaps()
	if aerr != nil {
		return Result{}, aerr
	}
	if strings.TrimSpace(path) == "" {
		return Result{Changed: false, Msg: fmt.Sprintf("%d active swap area(s)", len(areas)),
			Data: map[string]any{"areas": areas}}, nil
	}

	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, fmt.Errorf("swap: %w", err)
	}
	if state != "present" && state != "absent" {
		return Result{}, fmt.Errorf("swap: state must be present or absent, got %q", state)
	}
	if state == "absent" {
		return s.absent(ctx, path, params, areas, dryRun)
	}
	return s.present(ctx, path, params, areas, dryRun)
}

func (s *Swap) present(ctx context.Context, path string, params map[string]any,
	areas []swapArea, dryRun bool) (Result, error) {
	active := false
	for _, a := range areas {
		if a.Name == path {
			active = true
		}
	}
	if active {
		// Already on. Not "no-op because we gave up" — the area is in the requested state, which is
		// what idempotence means, and re-running swapon would error.
		return Result{Changed: false, Msg: "already active: " + path,
			Data: map[string]any{"path": path, "areas": areas}}, nil
	}

	size, _ := stringParam(params, "size", false, "")
	fi, statErr := os.Stat(path)
	isFile := statErr == nil && fi.Mode().IsRegular()
	missing := os.IsNotExist(statErr)
	var steps []string

	if missing {
		if size == "" {
			return Result{}, fmt.Errorf(
				"swap: %s does not exist and no size was given — refusing to guess how big a swap file should be", path)
		}
		steps = append(steps, "create "+size)
		isFile = true
	}
	// One question, asked once: is this already a swap area? A freshly created file never is; for
	// anything that exists, blkid says. An unreadable blkid answer counts as "not swap" — running
	// mkswap again on a swap area is harmless, skipping it on a raw device is not.
	kind := ""
	if !missing {
		if k, err := s.blkidType(ctx, path); err == nil {
			kind = k
		}
	}
	if kind != "swap" {
		// A device that already holds a filesystem must not be silently reformatted. Only a real,
		// recognised NON-swap type blocks: an empty answer means blkid saw nothing, which is the
		// normal state of a blank partition.
		if !isFile && kind != "" {
			if force, _ := boolParam(params, "force", false); !force {
				return Result{}, fmt.Errorf(
					"swap: %s already contains a %s filesystem — refusing to mkswap it (pass force=true if that is really intended)",
					path, kind)
			}
		}
		steps = append(steps, "mkswap")
	}
	steps = append(steps, "swapon")

	if dryRun {
		return Result{Changed: true, Msg: "would " + strings.Join(steps, " + ") + " " + path,
			Data: map[string]any{"path": path, "steps": steps, "areas": areas}}, nil
	}

	if missing {
		if err := s.createSwapFile(ctx, path, size); err != nil {
			return Result{}, err
		}
	}
	for _, st := range steps {
		if st == "mkswap" {
			if out, err := s.Runner(ctx, "mkswap", path); err != nil {
				return Result{}, fmt.Errorf("swap: mkswap %s: %w: %s", path, err, strings.TrimSpace(string(out)))
			}
		}
	}
	args := []string{path}
	if prio, err := intParam(params, "priority", -1); err == nil && prio >= 0 {
		args = append([]string{"--priority", strconv.Itoa(prio)}, args...)
	}
	if out, err := s.Runner(ctx, "swapon", args...); err != nil {
		return Result{}, fmt.Errorf("swap: swapon %s: %w: %s", path, err, strings.TrimSpace(string(out)))
	}
	after, _ := readProcSwaps()
	return Result{Changed: true, Msg: strings.Join(steps, " + ") + " " + path,
		Data: map[string]any{"path": path, "steps": steps, "areas": after}}, nil
}

func (s *Swap) absent(ctx context.Context, path string, params map[string]any,
	areas []swapArea, dryRun bool) (Result, error) {
	active := false
	for _, a := range areas {
		if a.Name == path {
			active = true
		}
	}
	remove, _ := boolParam(params, "remove_file", false)
	fi, statErr := os.Stat(path)
	isFile := statErr == nil && fi.Mode().IsRegular()
	willRemove := remove && isFile

	if !active && !willRemove {
		return Result{Changed: false, Msg: "not active: " + path,
			Data: map[string]any{"path": path, "areas": areas}}, nil
	}
	var steps []string
	if active {
		steps = append(steps, "swapoff")
	}
	if willRemove {
		steps = append(steps, "remove file")
	}
	if dryRun {
		return Result{Changed: true, Msg: "would " + strings.Join(steps, " + ") + " " + path,
			Data: map[string]any{"path": path, "steps": steps, "areas": areas}}, nil
	}
	if active {
		if out, err := s.Runner(ctx, "swapoff", path); err != nil {
			return Result{}, fmt.Errorf("swap: swapoff %s: %w: %s", path, err, strings.TrimSpace(string(out)))
		}
	}
	if willRemove {
		if err := os.Remove(path); err != nil {
			return Result{}, fmt.Errorf("swap: remove %s: %w", path, err)
		}
	}
	after, _ := readProcSwaps()
	return Result{Changed: true, Msg: strings.Join(steps, " + ") + " " + path,
		Data: map[string]any{"path": path, "steps": steps, "areas": after}}, nil
}

// createSwapFile allocates the file and locks its permissions down to 0600. A world-readable swap
// file exposes whatever the kernel paged out, and mkswap warns but proceeds — so this sets the mode
// BEFORE mkswap rather than relying on the warning being read.
func (s *Swap) createSwapFile(ctx context.Context, path, size string) error {
	if out, err := s.Runner(ctx, "fallocate", "-l", size, path); err != nil {
		// fallocate fails on filesystems without the syscall (some ext3, and older tmpfs); dd always
		// works and is the documented fallback. Not silent: the caller sees the step either way.
		blocks, derr := ddCountFor(size)
		if derr != nil {
			return fmt.Errorf("swap: fallocate %s failed (%w: %s) and size %q is not usable for dd",
				path, err, strings.TrimSpace(string(out)), size)
		}
		if out2, err2 := s.Runner(ctx, "dd", "if=/dev/zero", "of="+path, "bs=1M",
			"count="+strconv.Itoa(blocks)); err2 != nil {
			return fmt.Errorf("swap: creating %s failed: %w: %s", path, err2, strings.TrimSpace(string(out2)))
		}
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("swap: chmod 0600 %s: %w", path, err)
	}
	return nil
}

// blkidType reports what a path already contains ("swap", "ext4", …), or "" when blkid says
// nothing. An error means blkid could not answer, which the caller treats as "unknown".
func (s *Swap) blkidType(ctx context.Context, path string) (string, error) {
	out, err := s.Runner(ctx, "blkid", "-p", "-s", "TYPE", "-o", "value", path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

type swapArea struct {
	Name     string `json:"name"`
	Type     string `json:"type"` // "file" or "partition"
	SizeKB   int64  `json:"size_kb"`
	UsedKB   int64  `json:"used_kb"`
	Priority int    `json:"priority"`
}

// readProcSwaps parses /proc/swaps — the kernel's own list, which is why it is preferred over
// `swapon --show`: no binary needs to exist and the format has been stable for decades.
func readProcSwaps() ([]swapArea, error) {
	f, err := os.Open("/proc/swaps")
	if err != nil {
		if os.IsNotExist(err) {
			return []swapArea{}, nil // a kernel without swap support is not an error
		}
		return nil, fmt.Errorf("swap: read /proc/swaps: %w", err)
	}
	defer f.Close()

	areas := []swapArea{}
	sc := bufio.NewScanner(f)
	first := true
	for sc.Scan() {
		if first { // "Filename Type Size Used Priority"
			first = false
			continue
		}
		f := strings.Fields(sc.Text())
		if len(f) < 5 {
			continue
		}
		size, _ := strconv.ParseInt(f[2], 10, 64)
		used, _ := strconv.ParseInt(f[3], 10, 64)
		prio, _ := strconv.Atoi(f[4])
		areas = append(areas, swapArea{Name: f[0], Type: f[1], SizeKB: size, UsedKB: used, Priority: prio})
	}
	return areas, sc.Err()
}

// ddCountFor converts a size like "2G" or "512M" into whole megabytes for dd's count=.
func ddCountFor(size string) (int, error) {
	s := strings.TrimSpace(strings.ToUpper(size))
	mult := 1
	switch {
	case strings.HasSuffix(s, "G"):
		mult, s = 1024, strings.TrimSuffix(s, "G")
	case strings.HasSuffix(s, "M"):
		mult, s = 1, strings.TrimSuffix(s, "M")
	default:
		return 0, fmt.Errorf("size %q must end in M or G", size)
	}
	n, err := strconv.Atoi(strings.TrimSpace(strings.TrimSuffix(s, "B")))
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("size %q is not a positive number", size)
	}
	return n * mult, nil
}
