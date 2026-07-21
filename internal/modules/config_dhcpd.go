package modules

import (
	"fmt"
	"strings"
)

// dhcpdCodec parses and renders an ISC dhcpd.conf (/etc/dhcp/dhcpd.conf) into a
// structured, snapin-friendly shape: a small set of recognized global
// directives, the `subnet` blocks (DHCP scopes) and the `host` blocks (static
// reservations). Anything it does not model — unusual global statements and
// block types (class, shared-network, group, …) — is preserved verbatim under
// "extra" so a round-trip never loses data; only the recognized globals are
// re-emitted in a canonical order.
//
// Parsed shape:
//
//	{
//	  "globals":  {default_lease_time, max_lease_time, authoritative(bool),
//	               ddns_update_style, domain_name, domain_name_servers, log_facility},
//	  "subnets":  [{network, netmask, range_start, range_end, routers, dns}],
//	  "hosts":    [{name, mac, ip}],
//	  "extra":    ["<raw statement or block>", ...]
//	}
type dhcpdCodec struct{}

// dhcpdChunk is one top-level element of the file: either a simple statement
// (isBlock=false, header holds the text before ';') or a brace block
// (isBlock=true, header is the text before '{', body is the inner text).
type dhcpdChunk struct {
	header  string
	body    string
	isBlock bool
}

// splitDhcpd walks the file tracking brace depth and comment/quote state,
// splitting it into top-level chunks. Comments (# … to EOL) are stripped.
func splitDhcpd(data string) []dhcpdChunk {
	var chunks []dhcpdChunk
	var cur strings.Builder
	depth := 0
	blockBodyStart := -1
	inComment := false
	inQuote := false
	runes := []rune(data)
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		if inComment {
			if c == '\n' {
				inComment = false
			}
			continue
		}
		if c == '#' && !inQuote {
			inComment = true
			continue
		}
		if c == '"' {
			inQuote = !inQuote
			cur.WriteRune(c)
			continue
		}
		if inQuote {
			cur.WriteRune(c)
			continue
		}
		switch c {
		case '{':
			depth++
			if depth == 1 {
				blockBodyStart = cur.Len()
				cur.WriteRune(c)
				continue
			}
			cur.WriteRune(c)
		case '}':
			depth--
			cur.WriteRune(c)
			if depth == 0 {
				full := cur.String()
				header := strings.TrimSpace(full[:blockBodyStart])
				body := full[blockBodyStart:]
				body = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(body)[1:], "}")) // drop outer { }
				chunks = append(chunks, dhcpdChunk{header: header, body: body, isBlock: true})
				cur.Reset()
				blockBodyStart = -1
			}
		case ';':
			if depth == 0 {
				stmt := strings.TrimSpace(cur.String())
				if stmt != "" {
					chunks = append(chunks, dhcpdChunk{header: stmt, isBlock: false})
				}
				cur.Reset()
			} else {
				cur.WriteRune(c)
			}
		default:
			cur.WriteRune(c)
		}
	}
	return chunks
}

// bodyStatements splits a block body into its `;`-terminated statements
// (comments already stripped by splitDhcpd only at top level, so strip here too).
func bodyStatements(body string) []string {
	var out []string
	for _, part := range strings.Split(body, ";") {
		// strip comments within the block body
		var clean strings.Builder
		for _, line := range strings.Split(part, "\n") {
			if idx := strings.Index(line, "#"); idx >= 0 {
				line = line[:idx]
			}
			clean.WriteString(line)
			clean.WriteString(" ")
		}
		s := strings.TrimSpace(clean.String())
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func (c *dhcpdCodec) parse(data []byte) (map[string]any, error) {
	globals := map[string]any{}
	subnets := []any{}
	hosts := []any{}
	extra := []any{}

	for _, ch := range splitDhcpd(string(data)) {
		if !ch.isBlock {
			if !c.parseGlobal(ch.header, globals) {
				extra = append(extra, ch.header)
			}
			continue
		}
		fields := strings.Fields(ch.header)
		switch {
		case len(fields) >= 4 && fields[0] == "subnet" && fields[2] == "netmask":
			subnets = append(subnets, c.parseSubnet(fields, ch.body))
		case len(fields) >= 2 && fields[0] == "host":
			hosts = append(hosts, c.parseHost(fields[1], ch.body))
		default:
			extra = append(extra, ch.header+" {\n"+indentBody(ch.body)+"\n}")
		}
	}
	return map[string]any{"globals": globals, "subnets": subnets, "hosts": hosts, "extra": extra}, nil
}

// parseGlobal recognizes a simple top-level statement; returns false if it is
// not one we model (so the caller preserves it in extra).
func (c *dhcpdCodec) parseGlobal(stmt string, g map[string]any) bool {
	fields := strings.Fields(stmt)
	if len(fields) == 0 {
		return true
	}
	switch {
	case stmt == "authoritative":
		g["authoritative"] = true
		return true
	case fields[0] == "default-lease-time" && len(fields) >= 2:
		g["default_lease_time"] = fields[1]
		return true
	case fields[0] == "max-lease-time" && len(fields) >= 2:
		g["max_lease_time"] = fields[1]
		return true
	case fields[0] == "ddns-update-style" && len(fields) >= 2:
		g["ddns_update_style"] = fields[1]
		return true
	case fields[0] == "log-facility" && len(fields) >= 2:
		g["log_facility"] = fields[1]
		return true
	case fields[0] == "option" && len(fields) >= 3 && fields[1] == "domain-name":
		g["domain_name"] = strings.Trim(strings.Join(fields[2:], " "), `"`)
		return true
	case fields[0] == "option" && len(fields) >= 3 && fields[1] == "domain-name-servers":
		g["domain_name_servers"] = strings.Join(fields[2:], " ")
		return true
	}
	return false
}

func (c *dhcpdCodec) parseSubnet(headerFields []string, body string) map[string]any {
	s := map[string]any{"network": headerFields[1], "netmask": headerFields[3]}
	for _, stmt := range bodyStatements(body) {
		f := strings.Fields(stmt)
		switch {
		case f[0] == "range" && len(f) >= 3:
			s["range_start"] = f[1]
			s["range_end"] = f[2]
		case f[0] == "range" && len(f) == 2:
			s["range_start"] = f[1]
		case f[0] == "option" && len(f) >= 3 && f[1] == "routers":
			s["routers"] = strings.TrimSuffix(f[2], ";")
		case f[0] == "option" && len(f) >= 3 && f[1] == "domain-name-servers":
			s["dns"] = strings.Join(f[2:], " ")
		}
	}
	return s
}

func (c *dhcpdCodec) parseHost(name, body string) map[string]any {
	h := map[string]any{"name": name}
	for _, stmt := range bodyStatements(body) {
		f := strings.Fields(stmt)
		switch {
		case len(f) >= 3 && f[0] == "hardware" && f[1] == "ethernet":
			h["mac"] = f[2]
		case len(f) >= 2 && f[0] == "fixed-address":
			h["ip"] = f[1]
		}
	}
	return h
}

func (c *dhcpdCodec) render(_ []byte, values map[string]any, _ string) ([]byte, error) {
	var b strings.Builder
	b.WriteString("# Managed by agentic-mcp (dhcpd codec)\n\n")

	if g, ok := values["globals"].(map[string]any); ok {
		writeGlobal := func(key, directive string, quote bool) {
			if v, ok := g[key]; ok {
				s := fmt.Sprintf("%v", v)
				if quote {
					s = `"` + strings.Trim(s, `"`) + `"`
				}
				b.WriteString(directive + " " + s + ";\n")
			}
		}
		if v, ok := g["authoritative"]; ok {
			if bv, isBool := v.(bool); !isBool || bv {
				b.WriteString("authoritative;\n")
			}
		}
		writeGlobal("ddns_update_style", "ddns-update-style", false)
		writeGlobal("default_lease_time", "default-lease-time", false)
		writeGlobal("max_lease_time", "max-lease-time", false)
		writeGlobal("log_facility", "log-facility", false)
		writeGlobal("domain_name", "option domain-name", true)
		writeGlobal("domain_name_servers", "option domain-name-servers", false)
		b.WriteString("\n")
	}

	for _, sv := range asSlice(values["subnets"]) {
		s, ok := sv.(map[string]any)
		if !ok {
			continue
		}
		net := str(s["network"])
		mask := str(s["netmask"])
		if net == "" || mask == "" {
			continue
		}
		b.WriteString(fmt.Sprintf("subnet %s netmask %s {\n", net, mask))
		if rs := str(s["range_start"]); rs != "" {
			if re := str(s["range_end"]); re != "" {
				b.WriteString(fmt.Sprintf("    range %s %s;\n", rs, re))
			} else {
				b.WriteString(fmt.Sprintf("    range %s;\n", rs))
			}
		}
		if rt := str(s["routers"]); rt != "" {
			b.WriteString(fmt.Sprintf("    option routers %s;\n", rt))
		}
		if dns := str(s["dns"]); dns != "" {
			b.WriteString(fmt.Sprintf("    option domain-name-servers %s;\n", dns))
		}
		b.WriteString("}\n\n")
	}

	for _, hv := range asSlice(values["hosts"]) {
		h, ok := hv.(map[string]any)
		if !ok {
			continue
		}
		name := str(h["name"])
		if name == "" {
			continue
		}
		b.WriteString(fmt.Sprintf("host %s {\n", name))
		if mac := str(h["mac"]); mac != "" {
			b.WriteString(fmt.Sprintf("    hardware ethernet %s;\n", mac))
		}
		if ip := str(h["ip"]); ip != "" {
			b.WriteString(fmt.Sprintf("    fixed-address %s;\n", ip))
		}
		b.WriteString("}\n\n")
	}

	for _, ev := range asSlice(values["extra"]) {
		s := str(ev)
		if s == "" {
			continue
		}
		if strings.HasSuffix(strings.TrimSpace(s), "}") {
			b.WriteString(s + "\n\n")
		} else {
			b.WriteString(s + ";\n")
		}
	}
	return []byte(b.String()), nil
}

// asSlice coerces a []any / nil into a []any (JSON arrays decode to []any).
func asSlice(v any) []any {
	if s, ok := v.([]any); ok {
		return s
	}
	return nil
}

// str renders a value as a trimmed string ("" for nil).
func str(v any) string {
	if v == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprintf("%v", v))
}

// indentBody re-indents a preserved block body by 4 spaces per line.
func indentBody(body string) string {
	var out []string
	for _, line := range strings.Split(strings.TrimSpace(body), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out = append(out, "    "+line)
		}
	}
	return strings.Join(out, "\n")
}
