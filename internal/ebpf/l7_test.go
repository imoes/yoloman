package ebpf

import (
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func TestParseHTTPRequestLine(t *testing.T) {
	cases := []struct {
		in           string
		method, path string
	}{
		{"GET /users/123?q=1 HTTP/1.1\r\nHost: x\r\n\r\n", "GET", "/users/123?q=1"},
		{"POST /login HTTP/1.1\r\n", "POST", "/login"},
		{"garbage", "", ""},
	}
	for _, c := range cases {
		m, p := parseHTTPRequestLine([]byte(c.in))
		if m != c.method || p != c.path {
			t.Errorf("parseHTTPRequestLine(%q) = %q,%q; want %q,%q", c.in, m, p, c.method, c.path)
		}
	}
}

func TestHTTPStatusClass(t *testing.T) {
	for code, want := range map[int32]string{101: "1xx", 200: "2xx", 301: "3xx", 404: "4xx", 503: "5xx", 0: "unknown"} {
		if got := httpStatusClass(code); got != want {
			t.Errorf("httpStatusClass(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestDNSStatus(t *testing.T) {
	for rcode, want := range map[int32]string{0: "ok", 2: "servfail", 3: "nxdomain", 5: "refused", 9: "rcode9"} {
		if got := dnsStatus(rcode); got != want {
			t.Errorf("dnsStatus(%d) = %q, want %q", rcode, got, want)
		}
	}
}

func TestParseDNS(t *testing.T) {
	// Build a real DNS response for example.com A → 93.184.216.34.
	name := dnsmessage.MustNewName("example.com.")
	msg := dnsmessage.Message{
		Header:    dnsmessage.Header{Response: true},
		Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
		Answers: []dnsmessage.Resource{{
			Header: dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET},
			Body:   &dnsmessage.AResource{A: [4]byte{93, 184, 216, 34}},
		}},
	}
	packed, err := msg.Pack()
	if err != nil {
		t.Fatal(err)
	}
	gotName, gotType, answers := parseDNS(packed)
	if gotName != "example.com" || gotType != "A" {
		t.Errorf("parseDNS name/type = %q/%q, want example.com/A", gotName, gotType)
	}
	if len(answers) != 1 || answers[0] != "93.184.216.34" {
		t.Errorf("parseDNS answers = %v, want [93.184.216.34]", answers)
	}
	if _, _, _ = parseDNS([]byte("junk")); false {
		t.Fatal("unreachable")
	}
}
