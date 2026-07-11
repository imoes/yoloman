// Package starmodules is the agent-side Starlark module runtime (Block G3):
// it loads translated .star modules (+ their argspec sidecar) from disk,
// registers each as a modules.Module, and executes them via the shared
// internal/starmod runtime with a REAL capability backend (RealCaps) that
// performs actual system operations — honoring the same write gate and
// check_mode as the native Go modules.
package starmodules

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

const defaultRunTimeout = 5 * time.Minute

// RealCaps is the executing backend behind ctx.* (starmod.Capabilities). It
// carries the two orthogonal gates the module must never bypass:
//   - write: the agent-wide write gate (cfg.Write)
//   - moduleWrites: whether THIS module declared writes:true in its sidecar
//
// A mutating operation (ctx.run(mutates=True), ctx.file_write) requires BOTH
// — so a read-only module can never mutate, and no module mutates on a
// read-only agent. checkMode (dry-run) makes mutating ops predict, not act.
type RealCaps struct {
	checkMode    bool
	write        bool
	moduleWrites bool
	timeout      time.Duration
	procRoot     string // "" → /proc
}

// NewRealCaps builds a backend for one module invocation.
func NewRealCaps(checkMode, write, moduleWrites bool) *RealCaps {
	return &RealCaps{checkMode: checkMode, write: write, moduleWrites: moduleWrites, timeout: defaultRunTimeout, procRoot: "/proc"}
}

func (c *RealCaps) CheckMode() bool { return c.checkMode }

// mayMutate reports whether a state-changing op is permitted right now, or a
// fail()-worthy error explaining why not.
func (c *RealCaps) mayMutate(op string) error {
	if !c.moduleWrites {
		return fmt.Errorf("%s: this module is declared read-only (writes:false) and may not change the system", op)
	}
	if !c.write {
		return fmt.Errorf("%s: the write gate is closed (write=false)", op)
	}
	return nil
}

// Run executes argv with no shell. A mutating command is skipped in
// check_mode (returns skipped=True) and requires the write gate. A non-zero
// exit is returned as data (rc/stderr), not an error — the module inspects
// rc itself (the canonical `ctx.run(["systemctl","is-active",…]).rc` probe);
// only a failure to START the process is a fail(). ok_codes is advisory
// (the module decides) — kept for signature/validator parity.
func (c *RealCaps) Run(argv []string, mutates bool, _ []int) (starmod.RunResult, error) {
	if len(argv) == 0 {
		return starmod.RunResult{}, fmt.Errorf("run: empty argv")
	}
	if mutates {
		if c.checkMode {
			return starmod.RunResult{Skipped: true}, nil
		}
		if err := c.mayMutate("run(mutates=True)"); err != nil {
			return starmod.RunResult{}, err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if c.workdir() != "" {
		cmd.Dir = c.workdir()
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	rr := starmod.RunResult{Stdout: out.String(), Stderr: errb.String()}
	if err != nil {
		var exit *exec.ExitError
		if ok := asExitError(err, &exit); ok {
			rr.RC = exit.ExitCode()
			return rr, nil // non-zero exit is data, not a Go error
		}
		return starmod.RunResult{}, fmt.Errorf("run %q: %w", argv[0], err)
	}
	return rr, nil
}

func (c *RealCaps) workdir() string { return "" }

func (c *RealCaps) FileRead(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("file_read %q: %w", path, err)
	}
	return string(b), nil
}

// FileWrite writes content atomically-enough (write then chmod), reporting
// whether it changed. In check_mode it predicts without writing. Requires
// the write gate + a writing module.
func (c *RealCaps) FileWrite(path, content, mode string) (bool, error) {
	if err := c.mayMutate("file_write"); err != nil {
		return false, err
	}
	current, readErr := os.ReadFile(path)
	changed := readErr != nil || !bytes.Equal(current, []byte(content))
	if c.checkMode {
		return changed, nil // predict, don't write
	}
	perm := os.FileMode(0o644)
	if mode != "" {
		if m, err := strconv.ParseUint(mode, 8, 32); err == nil {
			perm = os.FileMode(m)
		}
	}
	if err := os.WriteFile(path, []byte(content), perm); err != nil {
		return false, fmt.Errorf("file_write %q: %w", path, err)
	}
	if mode != "" {
		_ = os.Chmod(path, perm) // enforce mode even if the file pre-existed
	}
	return changed, nil
}

func (c *RealCaps) FileExists(path string) (bool, error) {
	_, err := os.Stat(path)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, fmt.Errorf("file_exists %q: %w", path, err)
}

func (c *RealCaps) Stat(path string) (map[string]any, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("stat %q: %w", path, err)
	}
	out := map[string]any{
		"exists":  true,
		"size":    fi.Size(),
		"mode":    fmt.Sprintf("%04o", fi.Mode().Perm()),
		"is_dir":  fi.IsDir(),
		"is_link": fi.Mode()&os.ModeSymlink != 0,
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		out["uid"] = int64(st.Uid)
		out["gid"] = int64(st.Gid)
	}
	return out, nil
}

// Facts returns the subset the contract guarantees: os_family, distribution,
// distribution_version, hostname, architecture, kernel.
func (c *RealCaps) Facts() (map[string]any, error) {
	facts := map[string]any{
		"architecture": mapArch(runtime.GOARCH),
	}
	if h, err := os.Hostname(); err == nil {
		facts["hostname"] = h
	}
	if b, err := os.ReadFile(c.procRoot + "/sys/kernel/osrelease"); err == nil {
		facts["kernel"] = strings.TrimSpace(string(b))
	}
	id, version, codename := parseOSRelease("/etc/os-release")
	facts["distribution"] = id
	facts["distribution_version"] = version
	facts["distribution_codename"] = codename
	facts["os_family"] = osFamily(id)
	return facts, nil
}

func mapArch(goarch string) string {
	switch goarch {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	case "386":
		return "i386"
	default:
		return goarch
	}
}

func osFamily(id string) string {
	switch strings.ToLower(id) {
	case "debian", "ubuntu", "linuxmint", "raspbian":
		return "debian"
	case "rhel", "centos", "rocky", "almalinux", "fedora", "ol", "oraclelinux":
		return "redhat"
	case "":
		return ""
	default:
		return strings.ToLower(id)
	}
}

// parseOSRelease reads ID, VERSION_ID and VERSION_CODENAME from an os-release
// file (best-effort). The codename (e.g. "trixie", "jammy") is the Debian
// Security Tracker / Ubuntu USN release key used for CVE correlation.
func parseOSRelease(path string) (id, version, codename string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", "", ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		key, val, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		val = strings.Trim(val, `"'`)
		switch key {
		case "ID":
			id = val
		case "VERSION_ID":
			version = val
		case "VERSION_CODENAME":
			codename = val
		}
	}
	return id, version, codename
}

// asExitError is a tiny wrapper so the exec error assertion reads cleanly.
func asExitError(err error, target **exec.ExitError) bool {
	if e, ok := err.(*exec.ExitError); ok {
		*target = e
		return true
	}
	return false
}
