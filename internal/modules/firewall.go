package modules

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Firewall is a high-level, backend-agnostic host firewall manager modelled on
// the simplicity of `firewall-cmd`: allow/deny a port or named service, add
// SNAT/DNAT rules, and flip a host between "server" (no forwarding) and
// "router" (IP forwarding + masquerade) mode. It auto-detects the active
// backend — firewalld, ufw, or raw iptables — and translates each high-level
// operation to that backend's commands, so callers need not know which one the
// host runs.
//
// Backend selection (op-independent): a *running* firewalld wins, else an
// *active* ufw, else whichever of firewalld/ufw/iptables is merely installed
// (in that preference order); iptables is the universal Debian fallback.
// NAT (snat/dnat) and masquerade always go through the iptables `nat` table —
// the common denominator every backend sits on — and, on the iptables backend,
// rules are persisted with netfilter-persistent (installed on demand by
// op=enable, which is where iptables-persistent gets pulled in).
type Firewall struct {
	Runner CommandRunner
	// SysctlDir is where the router-mode ip_forward drop-in is written.
	// Overridable in tests. Defaults to /etc/sysctl.d.
	SysctlDir string
	// AgentListen is the daemon's own listen address (host:port), set by the
	// server wiring from cfg.Listen. op=enable whitelists this port FIRST so
	// turning the firewall on can never lock out the management channel — the
	// "Yoloman port". A caller may override it per-call with agent_port.
	AgentListen string
	// writeFile / removeFile abstract the sysctl drop-in file I/O for tests.
	writeFile  func(name string, data []byte, perm os.FileMode) error
	removeFile func(name string) error
}

// NewFirewall returns a Firewall backed by the real host tools.
func NewFirewall() *Firewall {
	return &Firewall{
		Runner:    defaultCommandRunner,
		SysctlDir: "/etc/sysctl.d",
		writeFile: os.WriteFile,
		removeFile: func(name string) error {
			if err := os.Remove(name); err != nil && !os.IsNotExist(err) {
				return err
			}
			return nil
		},
	}
}

func (f *Firewall) Name() string { return "firewall" }

func (f *Firewall) Description() string {
	return "" +
		"Backend-agnostic host firewall manager with the simplicity of firewall-cmd. " +
		"Auto-detects firewalld / ufw / iptables and translates a small set of high-level " +
		"operations to that backend. Operations (op): " +
		"detect (report backend + state), enable (turn firewall on; on the iptables backend " +
		"this installs iptables-persistent and saves current rules), disable, " +
		"allow / deny (a port like 8080/tcp or a named service like ssh, optionally from a " +
		"source CIDR), snat (masquerade or SNAT outgoing traffic — needs to_source and out_interface), " +
		"dnat (port-forward incoming traffic — needs protocol, dest_port, to_dest, in_interface), " +
		"set_mode (server = no IP forwarding; router = enable net.ipv4.ip_forward via a persistent " +
		"/etc/sysctl.d drop-in AND masquerade the LAN out the WAN interface), and list (current rules).\n\n" +
		"Cross-tool equivalents: Ansible ansible.builtin.iptables / posix.firewalld / community.general.ufw; " +
		"Salt firewalld/iptables states. This module is the one-stop simplified front-end over all three."
}

func (f *Firewall) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"op":            stringEnumProp("Operation to perform.", "detect", "enable", "disable", "allow", "deny", "snat", "dnat", "set_mode", "list"),
		"backend":       stringEnumProp("Force a backend instead of auto-detecting.", "firewalld", "ufw", "iptables"),
		"port":          stringProp(`Port spec for allow/deny, e.g. "8080/tcp" or "53/udp".`),
		"service":       stringProp(`Named service for allow/deny, e.g. "ssh", "http", "https", "dns".`),
		"source":        stringProp("Optional source address/CIDR to scope an allow/deny or SNAT rule."),
		"protocol":      stringProp(`Protocol for dnat, e.g. "tcp" or "udp". Default "tcp".`),
		"dest_port":     stringProp("Incoming port to forward (dnat)."),
		"to_dest":       stringProp(`DNAT target "ip" or "ip:port" (dnat).`),
		"to_source":     stringProp(`SNAT target IP, or "masquerade" for dynamic source NAT (snat).`),
		"in_interface":  stringProp("Inbound/WAN interface (dnat / router masquerade)."),
		"out_interface": stringProp("Outbound/WAN interface (snat / router masquerade)."),
		"lan_subnet":    stringProp(`LAN subnet to masquerade in router mode, e.g. "10.0.0.0/24".`),
		"mode":          stringEnumProp("Host mode for set_mode.", "server", "router"),
		"agent_port":    stringProp("Management (Yoloman) TCP port to whitelist first on enable. Defaults to the daemon's own listen port."),
		"dry_run":       boolProp("When true, report what would change without applying it.", false),
	}, "op")
}

func (f *Firewall) Writes() bool { return true }

// backendState is what `detect` reports.
type backendState struct {
	Backend         string `json:"backend"`
	FirewalldStatus string `json:"firewalld"` // running|installed|absent
	UfwStatus       string `json:"ufw"`       // active|installed|absent
	IptablesStatus  string `json:"iptables"`  // installed|absent
	IPForward       bool   `json:"ip_forward"`
	RouterMode      bool   `json:"router_mode"`
}

func (f *Firewall) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	op, err := stringParam(params, "op", true, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	backendOverride, _ := stringParam(params, "backend", false, "")

	switch op {
	case "detect", "list":
		st := f.detect(ctx)
		if backendOverride != "" {
			st.Backend = backendOverride
		}
		if op == "detect" {
			return Result{Changed: false, Msg: "backend " + st.Backend, Data: st}, nil
		}
		rules, err := f.list(ctx, st.Backend)
		if err != nil {
			return Result{}, err
		}
		return Result{Changed: false, Msg: "listed rules (" + st.Backend + ")", Data: map[string]any{"backend": st.Backend, "rules": rules, "state": st}}, nil
	}

	backend := backendOverride
	if backend == "" {
		backend = f.detect(ctx).Backend
	}
	if backend == "none" || backend == "" {
		return Result{}, fmt.Errorf("firewall: no supported backend (firewalld/ufw/iptables) found")
	}

	switch op {
	case "enable":
		agentPort, _ := stringParam(params, "agent_port", false, "")
		return f.enable(ctx, backend, agentPort, dryRun)
	case "disable":
		return f.disable(ctx, backend, dryRun)
	case "allow", "deny":
		return f.allowDeny(ctx, backend, op == "allow", params, dryRun)
	case "snat":
		return f.snat(ctx, params, dryRun, backend)
	case "dnat":
		return f.dnat(ctx, params, dryRun, backend)
	case "set_mode":
		return f.setMode(ctx, params, dryRun, backend)
	default:
		return Result{}, fmt.Errorf("firewall: unsupported op %q", op)
	}
}

// probe classifies a tool as running/active, installed, or absent by running
// its status command: nil error = the "up" state; a non-zero exit = installed
// but not up; a start failure (binary missing) = absent.
func (f *Firewall) probe(ctx context.Context, up, installed, absent string, name string, args ...string) string {
	_, err := f.Runner(ctx, name, args...)
	if err == nil {
		return up
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return installed
	}
	return absent
}

func (f *Firewall) detect(ctx context.Context) backendState {
	st := backendState{}
	// firewalld: `--state` prints "running" and exits 0 only when running.
	st.FirewalldStatus = f.probe(ctx, "running", "installed", "absent", "firewall-cmd", "--state")
	// ufw: `status` exits 0 whether active or inactive; distinguish by output.
	if out, err := f.Runner(ctx, "ufw", "status"); err == nil {
		if strings.Contains(strings.ToLower(string(out)), "status: active") {
			st.UfwStatus = "active"
		} else {
			st.UfwStatus = "installed"
		}
	} else {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			st.UfwStatus = "installed"
		} else {
			st.UfwStatus = "absent"
		}
	}
	st.IptablesStatus = f.probe(ctx, "installed", "installed", "absent", "iptables", "-S")
	// ip_forward
	if out, err := f.Runner(ctx, "sysctl", "-n", "net.ipv4.ip_forward"); err == nil {
		st.IPForward = strings.TrimSpace(string(out)) == "1"
	}
	st.RouterMode = st.IPForward

	switch {
	case st.FirewalldStatus == "running":
		st.Backend = "firewalld"
	case st.UfwStatus == "active":
		st.Backend = "ufw"
	case st.FirewalldStatus == "installed":
		st.Backend = "firewalld"
	case st.UfwStatus == "installed":
		st.Backend = "ufw"
	case st.IptablesStatus == "installed":
		st.Backend = "iptables"
	default:
		st.Backend = "none"
	}
	return st
}

func (f *Firewall) list(ctx context.Context, backend string) (string, error) {
	switch backend {
	case "firewalld":
		out, err := f.Runner(ctx, "firewall-cmd", "--list-all")
		return string(out), err
	case "ufw":
		out, err := f.Runner(ctx, "ufw", "status", "verbose")
		return string(out), err
	default:
		filterOut, _ := f.Runner(ctx, "iptables", "-S")
		natOut, _ := f.Runner(ctx, "iptables", "-t", "nat", "-S")
		return "# filter\n" + string(filterOut) + "\n# nat\n" + string(natOut), nil
	}
}

// agentPortSpec returns the management port to whitelist as "<port>/tcp",
// preferring an explicit override, else the daemon's own listen address.
func (f *Firewall) agentPortSpec(override string) string {
	p := strings.TrimSpace(override)
	if p == "" && f.AgentListen != "" {
		// AgentListen is host:port (host may be empty, e.g. ":8010").
		if idx := strings.LastIndex(f.AgentListen, ":"); idx >= 0 {
			p = f.AgentListen[idx+1:]
		}
	}
	if p == "" {
		return ""
	}
	return p + "/tcp"
}

// allowPort adds an ACCEPT rule for a "<port>/proto" spec on the given backend
// (a thin wrapper over allowDeny used to whitelist the management port).
func (f *Firewall) allowPort(ctx context.Context, backend, portSpec string, dryRun bool) error {
	_, err := f.allowDeny(ctx, backend, true, map[string]any{"port": portSpec}, dryRun)
	return err
}

func (f *Firewall) enable(ctx context.Context, backend, agentPortOverride string, dryRun bool) (Result, error) {
	// Whitelist the Yoloman management port FIRST — before the firewall is
	// actually turned on — so enabling can never sever the control channel.
	yolo := f.agentPortSpec(agentPortOverride)
	if yolo != "" {
		if err := f.allowPort(ctx, backend, yolo, dryRun); err != nil {
			return Result{}, fmt.Errorf("firewall: whitelisting management port %s: %w", yolo, err)
		}
	}

	switch backend {
	case "firewalld":
		if !dryRun {
			if _, err := f.Runner(ctx, "systemctl", "enable", "--now", "firewalld"); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: "firewalld enabled (management port " + yolo + " allowed)" + dryTag(dryRun)}, nil
	case "ufw":
		if !dryRun {
			if _, err := f.Runner(ctx, "ufw", "--force", "enable"); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: "ufw enabled (management port " + yolo + " allowed)" + dryTag(dryRun)}, nil
	default: // iptables: install persistence + save current ruleset
		if !dryRun {
			// env sets DEBIAN_FRONTEND then execs apt-get (no shell needed).
			if _, err := f.Runner(ctx, "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "iptables-persistent"); err != nil {
				return Result{}, fmt.Errorf("firewall: installing iptables-persistent: %w", err)
			}
			if err := f.persistIptables(ctx); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: "iptables-persistent installed + current rules saved (management port " + yolo + " allowed)" + dryTag(dryRun)}, nil
	}
}

func (f *Firewall) disable(ctx context.Context, backend string, dryRun bool) (Result, error) {
	switch backend {
	case "firewalld":
		if !dryRun {
			if _, err := f.Runner(ctx, "systemctl", "disable", "--now", "firewalld"); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: "firewalld disabled" + dryTag(dryRun)}, nil
	case "ufw":
		if !dryRun {
			if _, err := f.Runner(ctx, "ufw", "disable"); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: "ufw disabled" + dryTag(dryRun)}, nil
	default:
		return Result{Changed: false, Msg: "iptables backend has no service to disable; flush rules manually if intended"}, nil
	}
}

// splitPort turns "8080/tcp" into ("8080","tcp"); defaults proto to tcp.
func splitPort(spec string) (port, proto string) {
	parts := strings.SplitN(spec, "/", 2)
	port = parts[0]
	proto = "tcp"
	if len(parts) == 2 && parts[1] != "" {
		proto = parts[1]
	}
	return
}

func (f *Firewall) allowDeny(ctx context.Context, backend string, allow bool, params map[string]any, dryRun bool) (Result, error) {
	port, _ := stringParam(params, "port", false, "")
	service, _ := stringParam(params, "service", false, "")
	source, _ := stringParam(params, "source", false, "")
	if port == "" && service == "" {
		return Result{}, fmt.Errorf("firewall: allow/deny needs a port or a service")
	}

	switch backend {
	case "firewalld":
		args := []string{"--permanent"}
		verb := "--add-"
		if !allow {
			verb = "--remove-"
		}
		if service != "" {
			args = append(args, verb+"service="+service)
		} else {
			args = append(args, verb+"port="+port)
		}
		if !dryRun {
			if _, err := f.Runner(ctx, "firewall-cmd", args...); err != nil {
				return Result{}, err
			}
			if _, err := f.Runner(ctx, "firewall-cmd", "--reload"); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: fmt.Sprintf("firewalld %v%s", args, dryTag(dryRun))}, nil

	case "ufw":
		// ufw: `allow`/`deny` <port/proto|service>, or `delete allow ...`.
		target := service
		if target == "" {
			target = port
		}
		var args []string
		if allow {
			args = []string{"allow"}
		} else {
			args = []string{"deny"}
		}
		if source != "" {
			args = []string{"allow", "from", source, "to", "any", "port", strings.SplitN(port, "/", 2)[0]}
			if !allow {
				args[0] = "deny"
			}
		} else {
			args = append(args, target)
		}
		if !dryRun {
			if _, err := f.Runner(ctx, "ufw", args...); err != nil {
				return Result{}, err
			}
		}
		return Result{Changed: true, Msg: fmt.Sprintf("ufw %v%s", args, dryTag(dryRun))}, nil

	default: // iptables
		p, proto := splitPort(port)
		if service != "" && port == "" {
			// resolve a named service to a port via getent.
			out, err := f.Runner(ctx, "getent", "services", service)
			if err != nil {
				return Result{}, fmt.Errorf("firewall: unknown service %q (provide an explicit port for the iptables backend): %w", service, err)
			}
			// getent output: "ssh                   22/tcp"
			fields := strings.Fields(string(out))
			if len(fields) >= 2 {
				p, proto = splitPort(fields[1])
			}
		}
		target := "ACCEPT"
		if !allow {
			target = "DROP"
		}
		rule := []string{"INPUT", "-p", proto, "--dport", p}
		if source != "" {
			rule = append(rule, "-s", source)
		}
		rule = append(rule, "-j", target)
		if err := f.ensureIptablesRule(ctx, "filter", rule, dryRun); err != nil {
			return Result{}, err
		}
		if !dryRun {
			_ = f.persistIptables(ctx)
		}
		return Result{Changed: true, Msg: fmt.Sprintf("iptables -A %v%s", rule, dryTag(dryRun))}, nil
	}
}

func (f *Firewall) snat(ctx context.Context, params map[string]any, dryRun bool, backend string) (Result, error) {
	source, _ := stringParam(params, "source", false, "")
	toSource, _ := stringParam(params, "to_source", false, "")
	outIf, _ := stringParam(params, "out_interface", false, "")
	if toSource == "" {
		return Result{}, fmt.Errorf("firewall: snat needs to_source (an IP or \"masquerade\")")
	}
	rule := []string{"POSTROUTING"}
	if source != "" {
		rule = append(rule, "-s", source)
	}
	if outIf != "" {
		rule = append(rule, "-o", outIf)
	}
	if strings.EqualFold(toSource, "masquerade") {
		rule = append(rule, "-j", "MASQUERADE")
	} else {
		rule = append(rule, "-j", "SNAT", "--to-source", toSource)
	}
	if err := f.ensureIptablesRule(ctx, "nat", rule, dryRun); err != nil {
		return Result{}, err
	}
	if !dryRun {
		_ = f.persistIptables(ctx)
	}
	return Result{Changed: true, Msg: fmt.Sprintf("iptables -t nat -A %v%s", rule, dryTag(dryRun))}, nil
}

func (f *Firewall) dnat(ctx context.Context, params map[string]any, dryRun bool, backend string) (Result, error) {
	proto, _ := stringParam(params, "protocol", false, "tcp")
	destPort, _ := stringParam(params, "dest_port", false, "")
	toDest, _ := stringParam(params, "to_dest", false, "")
	inIf, _ := stringParam(params, "in_interface", false, "")
	if destPort == "" || toDest == "" {
		return Result{}, fmt.Errorf("firewall: dnat needs dest_port and to_dest")
	}
	if proto == "" {
		proto = "tcp"
	}
	rule := []string{"PREROUTING"}
	if inIf != "" {
		rule = append(rule, "-i", inIf)
	}
	rule = append(rule, "-p", proto, "--dport", destPort, "-j", "DNAT", "--to-destination", toDest)
	if err := f.ensureIptablesRule(ctx, "nat", rule, dryRun); err != nil {
		return Result{}, err
	}
	if !dryRun {
		_ = f.persistIptables(ctx)
	}
	return Result{Changed: true, Msg: fmt.Sprintf("iptables -t nat -A %v%s", rule, dryTag(dryRun))}, nil
}

func (f *Firewall) setMode(ctx context.Context, params map[string]any, dryRun bool, backend string) (Result, error) {
	mode, err := stringParam(params, "mode", true, "")
	if err != nil {
		return Result{}, err
	}
	dropin := filepath.Join(f.SysctlDir, "99-agentic-router.conf")
	if mode == "router" {
		outIf, _ := stringParam(params, "out_interface", false, "")
		lan, _ := stringParam(params, "lan_subnet", false, "")
		if !dryRun {
			if _, err := f.Runner(ctx, "sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
				return Result{}, err
			}
			if err := f.writeFile(dropin, []byte("# Managed by agentic-mcp firewall (router mode)\nnet.ipv4.ip_forward=1\n"), 0o644); err != nil {
				return Result{}, fmt.Errorf("firewall: writing %s: %w", dropin, err)
			}
			// masquerade the LAN out the WAN interface so router clients get NAT.
			rule := []string{"POSTROUTING"}
			if lan != "" {
				rule = append(rule, "-s", lan)
			}
			if outIf != "" {
				rule = append(rule, "-o", outIf)
			}
			rule = append(rule, "-j", "MASQUERADE")
			if err := f.ensureIptablesRule(ctx, "nat", rule, false); err != nil {
				return Result{}, err
			}
			_ = f.persistIptables(ctx)
		}
		return Result{Changed: true, Msg: "router mode: ip_forward=1 + masquerade" + dryTag(dryRun)}, nil
	}
	// server mode: turn forwarding off and drop the drop-in.
	if !dryRun {
		if _, err := f.Runner(ctx, "sysctl", "-w", "net.ipv4.ip_forward=0"); err != nil {
			return Result{}, err
		}
		if err := f.removeFile(dropin); err != nil {
			return Result{}, fmt.Errorf("firewall: removing %s: %w", dropin, err)
		}
	}
	return Result{Changed: true, Msg: "server mode: ip_forward=0" + dryTag(dryRun)}, nil
}

// ensureIptablesRule adds a rule idempotently via `iptables -C` (like the
// iptables module), in the given table.
func (f *Firewall) ensureIptablesRule(ctx context.Context, table string, rule []string, dryRun bool) error {
	checkArgs := append([]string{"-t", table, "-C"}, rule...)
	_, err := f.Runner(ctx, "iptables", checkArgs...)
	if err == nil {
		return nil // already present
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("iptables: checking rule: %w", err)
	}
	if dryRun {
		return nil
	}
	addArgs := append([]string{"-t", table, "-A"}, rule...)
	if _, err := f.Runner(ctx, "iptables", addArgs...); err != nil {
		return fmt.Errorf("iptables: adding rule: %w", err)
	}
	return nil
}

// persistIptables saves the current ruleset so it survives reboot. Prefers
// netfilter-persistent (from iptables-persistent); a missing binary is not an
// error (the caller may not have enabled persistence yet).
func (f *Firewall) persistIptables(ctx context.Context) error {
	_, err := f.Runner(ctx, "netfilter-persistent", "save")
	if err == nil {
		return nil
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return nil // binary absent → persistence not set up yet; ignore
	}
	return fmt.Errorf("firewall: netfilter-persistent save: %w", err)
}

func dryTag(dry bool) string {
	if dry {
		return " (dry-run)"
	}
	return ""
}
