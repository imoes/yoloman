package modules

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// fakeFirewallRunner records every invocation and returns canned
// output/errors keyed by the command's first argument or a substring.
type fakeFirewallRunner struct {
	calls   []string
	replies map[string]fakeReply // key: "name arg0" prefix match
}

type fakeReply struct {
	out []byte
	err error
}

func (r *fakeFirewallRunner) run(_ context.Context, name string, args ...string) ([]byte, error) {
	line := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.calls = append(r.calls, line)
	for key, rep := range r.replies {
		if strings.HasPrefix(line, key) {
			return rep.out, rep.err
		}
	}
	return nil, nil
}

func (r *fakeFirewallRunner) called(substr string) bool {
	for _, c := range r.calls {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}

// exitErr fabricates an *exec.ExitError-like failure via a real failing
// command so errors.As(&exec.ExitError) matches (used to signal "rule absent"
// / "installed but not running").
func exitErr(t *testing.T) error {
	t.Helper()
	err := exec.Command("false").Run()
	if _, ok := err.(*exec.ExitError); !ok {
		t.Fatalf("expected ExitError from `false`, got %T", err)
	}
	return err
}

func newTestFirewall(r *fakeFirewallRunner) *Firewall {
	return &Firewall{
		Runner:      r.run,
		SysctlDir:   os.TempDir(),
		AgentListen: ":8010",
		writeFile:   func(string, []byte, os.FileMode) error { return nil },
		removeFile:  func(string) error { return nil },
	}
}

func TestFirewall_DetectPrefersRunningFirewalld(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"firewall-cmd --state": {out: []byte("running\n")},
		"ufw status":           {out: []byte("Status: inactive\n")},
		"iptables -S":          {out: []byte("-P INPUT ACCEPT\n")},
	}}
	fw := newTestFirewall(r)
	res, err := fw.Run(context.Background(), map[string]any{"op": "detect"}, false)
	if err != nil {
		t.Fatal(err)
	}
	st := res.Data.(backendState)
	if st.Backend != "firewalld" {
		t.Errorf("want firewalld, got %q", st.Backend)
	}
}

func TestFirewall_DetectFallsBackToIptables(t *testing.T) {
	ee := exitErr(t)
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"firewall-cmd --state": {err: &exec.Error{Name: "firewall-cmd", Err: exec.ErrNotFound}}, // absent
		"ufw status":           {err: &exec.Error{Name: "ufw", Err: exec.ErrNotFound}},          // absent
		"iptables -S":          {out: []byte("-P INPUT ACCEPT\n")},
		"sysctl -n":            {err: ee},
	}}
	fw := newTestFirewall(r)
	res, _ := fw.Run(context.Background(), map[string]any{"op": "detect"}, false)
	if st := res.Data.(backendState); st.Backend != "iptables" {
		t.Errorf("want iptables fallback, got %q", st.Backend)
	}
}

func TestFirewall_EnableIptablesWhitelistsAgentPortFirst(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		// force iptables backend via explicit param; -C says "rule absent"
		"iptables -t filter -C": {err: exitErr(t)},
	}}
	fw := newTestFirewall(r)
	_, err := fw.Run(context.Background(), map[string]any{"op": "enable", "backend": "iptables"}, false)
	if err != nil {
		t.Fatal(err)
	}
	// The management port (8010/tcp) ACCEPT rule must be added, and
	// iptables-persistent installed.
	if !r.called("iptables -t filter -A INPUT -p tcp --dport 8010 -j ACCEPT") {
		t.Errorf("agent port not whitelisted; calls=%v", r.calls)
	}
	if !r.called("apt-get install -y iptables-persistent") {
		t.Errorf("iptables-persistent not installed; calls=%v", r.calls)
	}
	// Order: the ACCEPT rule must come before the install.
	var idxRule, idxInstall = -1, -1
	for i, c := range r.calls {
		if strings.Contains(c, "-A INPUT -p tcp --dport 8010") {
			idxRule = i
		}
		if strings.Contains(c, "iptables-persistent") && idxInstall == -1 {
			idxInstall = i
		}
	}
	if idxRule == -1 || idxInstall == -1 || idxRule > idxInstall {
		t.Errorf("management port must be allowed before enabling persistence (rule@%d, install@%d)", idxRule, idxInstall)
	}
}

func TestFirewall_AllowPortFirewalld(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{}}
	fw := newTestFirewall(r)
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "allow", "backend": "firewalld", "port": "8080/tcp",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.called("firewall-cmd --permanent --add-port=8080/tcp") {
		t.Errorf("add-port not issued; calls=%v", r.calls)
	}
	if !r.called("firewall-cmd --reload") {
		t.Errorf("reload not issued; calls=%v", r.calls)
	}
}

func TestFirewall_SnatMasquerade(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"iptables -t nat -C": {err: exitErr(t)}, // rule absent → add
	}}
	fw := newTestFirewall(r)
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "snat", "backend": "iptables", "to_source": "masquerade",
		"source": "10.0.0.0/24", "out_interface": "eth0",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.called("iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE") {
		t.Errorf("masquerade rule not added; calls=%v", r.calls)
	}
}

func TestFirewall_DnatPortForward(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"iptables -t nat -C": {err: exitErr(t)},
	}}
	fw := newTestFirewall(r)
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "dnat", "backend": "iptables", "protocol": "tcp",
		"dest_port": "443", "to_dest": "10.0.0.5:443", "in_interface": "eth0",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.called("iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 -j DNAT --to-destination 10.0.0.5:443") {
		t.Errorf("DNAT rule not added; calls=%v", r.calls)
	}
}

func TestFirewall_RouterModeEnablesForwardingAndMasquerade(t *testing.T) {
	wrote := ""
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"iptables -t nat -C": {err: exitErr(t)},
	}}
	fw := newTestFirewall(r)
	fw.writeFile = func(name string, data []byte, _ os.FileMode) error {
		wrote = name + ":" + string(data)
		return nil
	}
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "set_mode", "backend": "iptables", "mode": "router",
		"out_interface": "eth0", "lan_subnet": "10.0.0.0/24",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.called("sysctl -w net.ipv4.ip_forward=1") {
		t.Errorf("ip_forward not set at runtime; calls=%v", r.calls)
	}
	if !strings.Contains(wrote, "net.ipv4.ip_forward=1") {
		t.Errorf("sysctl drop-in not written: %q", wrote)
	}
	if !r.called("iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE") {
		t.Errorf("router masquerade not added; calls=%v", r.calls)
	}
}

func TestFirewall_ServerModeDisablesForwarding(t *testing.T) {
	removed := ""
	r := &fakeFirewallRunner{replies: map[string]fakeReply{}}
	fw := newTestFirewall(r)
	fw.removeFile = func(name string) error { removed = name; return nil }
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "set_mode", "backend": "iptables", "mode": "server",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.called("sysctl -w net.ipv4.ip_forward=0") {
		t.Errorf("ip_forward not disabled; calls=%v", r.calls)
	}
	if !strings.Contains(removed, "99-agentic-router.conf") {
		t.Errorf("router drop-in not removed: %q", removed)
	}
}

func TestFirewall_DryRunAddsNothing(t *testing.T) {
	r := &fakeFirewallRunner{replies: map[string]fakeReply{
		"iptables -t filter -C": {err: exitErr(t)},
	}}
	fw := newTestFirewall(r)
	_, err := fw.Run(context.Background(), map[string]any{
		"op": "allow", "backend": "iptables", "port": "9000/tcp",
	}, true)
	if err != nil {
		t.Fatal(err)
	}
	if r.called("-A INPUT") {
		t.Errorf("dry-run must not add rules; calls=%v", r.calls)
	}
}
