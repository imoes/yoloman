package modules

import (
	"strings"
	"testing"
)

const sampleDhcpd = `# global settings
authoritative;
default-lease-time 600;
max-lease-time 7200;
option domain-name "example.org";
option domain-name-servers 8.8.8.8, 8.8.4.4;

subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;   # dynamic pool
    option routers 10.0.0.1;
    option domain-name-servers 10.0.0.1;
}

host printer {
    hardware ethernet 00:11:22:33:44:55;
    fixed-address 10.0.0.50;
}

class "foo" {
    match hardware;
}
`

func TestDhcpdCodec_Parse(t *testing.T) {
	c := &dhcpdCodec{}
	got, err := c.parse([]byte(sampleDhcpd))
	if err != nil {
		t.Fatal(err)
	}
	g := got["globals"].(map[string]any)
	if g["authoritative"] != true || g["default_lease_time"] != "600" || g["domain_name"] != "example.org" {
		t.Errorf("globals wrong: %v", g)
	}
	subnets := got["subnets"].([]any)
	if len(subnets) != 1 {
		t.Fatalf("want 1 subnet, got %d", len(subnets))
	}
	s := subnets[0].(map[string]any)
	if s["network"] != "10.0.0.0" || s["netmask"] != "255.255.255.0" || s["range_start"] != "10.0.0.100" || s["range_end"] != "10.0.0.200" || s["routers"] != "10.0.0.1" {
		t.Errorf("subnet wrong: %v", s)
	}
	hosts := got["hosts"].([]any)
	if len(hosts) != 1 {
		t.Fatalf("want 1 host, got %d", len(hosts))
	}
	h := hosts[0].(map[string]any)
	if h["name"] != "printer" || h["mac"] != "00:11:22:33:44:55" || h["ip"] != "10.0.0.50" {
		t.Errorf("host wrong: %v", h)
	}
	// the unmodeled `class` block must be preserved
	extra := got["extra"].([]any)
	if len(extra) != 1 || !strings.Contains(str(extra[0]), "class \"foo\"") {
		t.Errorf("extra class block not preserved: %v", extra)
	}
}

func TestDhcpdCodec_RoundTrip(t *testing.T) {
	c := &dhcpdCodec{}
	parsed, _ := c.parse([]byte(sampleDhcpd))
	out, err := c.render(nil, parsed, "merge")
	if err != nil {
		t.Fatal(err)
	}
	// re-parse and confirm structure survives
	again, _ := c.parse(out)
	if len(again["subnets"].([]any)) != 1 || len(again["hosts"].([]any)) != 1 {
		t.Errorf("round-trip lost blocks:\n%s", out)
	}
	g := again["globals"].(map[string]any)
	if g["domain_name"] != "example.org" || g["default_lease_time"] != "600" {
		t.Errorf("round-trip lost globals: %v\n%s", g, out)
	}
	if !strings.Contains(string(out), `class "foo"`) {
		t.Errorf("round-trip lost extra block:\n%s", out)
	}
}

func TestDhcpdCodec_AddReservation(t *testing.T) {
	c := &dhcpdCodec{}
	parsed, _ := c.parse([]byte(sampleDhcpd))
	hosts := parsed["hosts"].([]any)
	hosts = append(hosts, map[string]any{"name": "nas", "mac": "aa:bb:cc:dd:ee:ff", "ip": "10.0.0.60"})
	parsed["hosts"] = hosts
	out, _ := c.render(nil, parsed, "merge")
	if !strings.Contains(string(out), "host nas {") || !strings.Contains(string(out), "fixed-address 10.0.0.60;") {
		t.Errorf("new reservation not rendered:\n%s", out)
	}
}
