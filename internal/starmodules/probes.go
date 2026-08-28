package starmodules

// Client-side network probes — the Go primitives behind active service checks
// (the Checkmk "Services" rules: check_http, check_tcp, check_dns, …). The
// probe collects raw facts (status, timing, TLS cert, banner, records); the
// Starlark check grades them OK/WARN/CRIT against its parameters. Mirrors how
// Checkmk wraps the monitoring-plugins binaries: the binary measures, the
// ruleset grades — here the "binary" is native Go, so the agent stays a
// dependency-free static binary.
//
// A transport failure (refused, timeout, TLS error, NXDOMAIN) is a RESULT
// ("error" key), not a Go error — an unreachable endpoint is exactly what a
// service check exists to report.

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

const (
	probeDefaultTimeout = 10 * time.Second
	probeMaxBody        = 256 * 1024 // enough for content matching, bounded
)

// Probe implements starmod.Capabilities.Probe.
func (c *RealCaps) Probe(kind string, params map[string]any) (map[string]any, error) {
	if params == nil {
		params = map[string]any{}
	}
	switch kind {
	case "http":
		return probeHTTP(params), nil
	case "tcp":
		return probeTCP(params), nil
	case "dns":
		return probeDNS(params), nil
	default:
		return nil, fmt.Errorf("probe: unknown kind %q (want http|tcp|dns)", kind)
	}
}

func pStr(p map[string]any, key, def string) string {
	if v, ok := p[key].(string); ok && v != "" {
		return v
	}
	return def
}

func pFloat(p map[string]any, key string, def float64) float64 {
	switch v := p[key].(type) {
	case float64:
		return v
	case int:
		return float64(v)
	case int64:
		return float64(v)
	}
	return def
}

func pBool(p map[string]any, key string, def bool) bool {
	if v, ok := p[key].(bool); ok {
		return v
	}
	return def
}

func pTimeout(p map[string]any) time.Duration {
	if s := pFloat(p, "timeout_s", 0); s > 0 {
		return time.Duration(s * float64(time.Second))
	}
	return probeDefaultTimeout
}

// probeHTTP: url, method, headers{}, body, timeout_s, verify_tls, follow_redirects,
// user_agent, auth_user/auth_password → status_code, response_ms, body (truncated),
// body_bytes, headers{}, final_url, cert_days_left/cert_subject (https), error.
func probeHTTP(p map[string]any) map[string]any {
	out := map[string]any{"error": ""}
	url := pStr(p, "url", "")
	if url == "" {
		out["error"] = "http probe: url is required"
		return out
	}
	method := strings.ToUpper(pStr(p, "method", "GET"))
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: !pBool(p, "verify_tls", true)}, //nolint:gosec — operator-controlled service check
		Proxy:           http.ProxyFromEnvironment,
	}
	client := &http.Client{Timeout: pTimeout(p), Transport: transport}
	if !pBool(p, "follow_redirects", true) {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	var bodyReader io.Reader
	if b := pStr(p, "body", ""); b != "" {
		bodyReader = strings.NewReader(b)
	}
	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		out["error"] = err.Error()
		return out
	}
	req.Header.Set("User-Agent", pStr(p, "user_agent", "bossman-check/1.0"))
	if hs, ok := p["headers"].(map[string]any); ok {
		for k, v := range hs {
			req.Header.Set(k, fmt.Sprintf("%v", v))
		}
	}
	if u := pStr(p, "auth_user", ""); u != "" {
		req.SetBasicAuth(u, pStr(p, "auth_password", ""))
	}
	if vh := pStr(p, "virtual_host", ""); vh != "" {
		req.Host = vh
	}

	start := time.Now()
	resp, err := client.Do(req)
	out["response_ms"] = float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		out["error"] = err.Error()
		return out
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, probeMaxBody))
	out["response_ms"] = float64(time.Since(start).Microseconds()) / 1000.0

	out["status_code"] = resp.StatusCode
	out["body"] = string(bodyBytes)
	out["body_bytes"] = len(bodyBytes)
	out["final_url"] = resp.Request.URL.String()
	hdrs := map[string]any{}
	for k := range resp.Header {
		hdrs[k] = resp.Header.Get(k)
	}
	out["headers"] = hdrs
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		cert := resp.TLS.PeerCertificates[0]
		out["cert_days_left"] = int(time.Until(cert.NotAfter).Hours() / 24)
		out["cert_subject"] = cert.Subject.CommonName
		out["cert_issuer"] = cert.Issuer.CommonName
		out["cert_not_after"] = cert.NotAfter.UTC().Format(time.RFC3339)
	}
	return out
}

// probeTCP: host, port, timeout_s, send, expect_bytes (how much to read),
// tls (wrap connection) → connected, connect_ms, received, cert_* (tls), error.
func probeTCP(p map[string]any) map[string]any {
	out := map[string]any{"error": "", "connected": false}
	host := pStr(p, "host", "")
	port := int(pFloat(p, "port", 0))
	if host == "" || port <= 0 {
		out["error"] = "tcp probe: host and port are required"
		return out
	}
	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	timeout := pTimeout(p)
	start := time.Now()
	var conn net.Conn
	var err error
	if pBool(p, "tls", false) {
		conn, err = tls.DialWithDialer(&net.Dialer{Timeout: timeout}, "tcp", addr,
			&tls.Config{InsecureSkipVerify: !pBool(p, "verify_tls", true)}) //nolint:gosec
	} else {
		conn, err = net.DialTimeout("tcp", addr, timeout)
	}
	out["connect_ms"] = float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		out["error"] = err.Error()
		return out
	}
	defer conn.Close()
	out["connected"] = true
	if tc, ok := conn.(*tls.Conn); ok {
		state := tc.ConnectionState()
		if len(state.PeerCertificates) > 0 {
			cert := state.PeerCertificates[0]
			out["cert_days_left"] = int(time.Until(cert.NotAfter).Hours() / 24)
			out["cert_subject"] = cert.Subject.CommonName
		}
	}
	if send := pStr(p, "send", ""); send != "" {
		_ = conn.SetWriteDeadline(time.Now().Add(timeout))
		if _, werr := conn.Write([]byte(send)); werr != nil {
			out["error"] = werr.Error()
			return out
		}
	}
	// Read a banner/response when asked for (expect_bytes > 0) or when we sent
	// something (a send without a read is rarely useful).
	expect := int(pFloat(p, "expect_bytes", 0))
	if expect <= 0 && pStr(p, "send", "") != "" {
		expect = 1024
	}
	if expect > 0 {
		if expect > probeMaxBody {
			expect = probeMaxBody
		}
		_ = conn.SetReadDeadline(time.Now().Add(timeout))
		buf := make([]byte, expect)
		n, _ := conn.Read(buf) // timeout/EOF after partial data is fine — report what arrived
		out["received"] = string(buf[:n])
	}
	return out
}

// probeDNS: name, rtype (A|AAAA|CNAME|MX|NS|TXT), timeout_s → records[],
// resolve_ms, error. Uses the host's resolver configuration.
func probeDNS(p map[string]any) map[string]any {
	out := map[string]any{"error": "", "records": []any{}}
	name := pStr(p, "name", "")
	if name == "" {
		out["error"] = "dns probe: name is required"
		return out
	}
	rtype := strings.ToUpper(pStr(p, "rtype", "A"))
	timeout := pTimeout(p)
	resolver := &net.Resolver{}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	start := time.Now()
	var records []any
	var err error
	switch rtype {
	case "A", "AAAA":
		var ips []net.IPAddr
		ips, err = resolver.LookupIPAddr(ctx, name)
		for _, ip := range ips {
			is4 := ip.IP.To4() != nil
			if (rtype == "A" && is4) || (rtype == "AAAA" && !is4) {
				records = append(records, ip.IP.String())
			}
		}
	case "CNAME":
		var cname string
		cname, err = resolver.LookupCNAME(ctx, name)
		if cname != "" {
			records = append(records, strings.TrimSuffix(cname, "."))
		}
	case "MX":
		var mxs []*net.MX
		mxs, err = resolver.LookupMX(ctx, name)
		for _, mx := range mxs {
			records = append(records, fmt.Sprintf("%d %s", mx.Pref, strings.TrimSuffix(mx.Host, ".")))
		}
	case "NS":
		var nss []*net.NS
		nss, err = resolver.LookupNS(ctx, name)
		for _, ns := range nss {
			records = append(records, strings.TrimSuffix(ns.Host, "."))
		}
	case "TXT":
		var txts []string
		txts, err = resolver.LookupTXT(ctx, name)
		for _, t := range txts {
			records = append(records, t)
		}
	default:
		out["error"] = fmt.Sprintf("dns probe: unsupported rtype %q", rtype)
		return out
	}
	out["resolve_ms"] = float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		out["error"] = err.Error()
	}
	out["records"] = records
	return out
}
