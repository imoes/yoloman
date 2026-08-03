# Translated Checkmk check: cisco_vpn_tunnel -> read-only Starlark check module
# Monitors Cisco VPN tunnels (IPsec Phase 1 + Phase 2) via SNMP.
# Discovery enumerates tunnels by remote IP; check reports per-tunnel bandwidth rates.

def _networkbandwidth(bits_per_sec):
    bps = float(bits_per_sec)
    if bps >= 1e9:
        return "%f Gbps" % (bps / 1e9)
    if bps >= 1e6:
        return "%f Mbps" % (bps / 1e6)
    if bps >= 1e3:
        return "%f Kbps" % (bps / 1e3)
    return "%f bps" % bps

def _get_rate(value_store, key, now, current):
    prev_t = value_store.get(key + "_prev_t")
    prev = value_store.get(key + "_prev")
    if prev == None or prev_t == None:
        value_store[key + "_prev"] = current
        value_store[key + "_prev_t"] = now
        return None
    elapsed = now - prev_t
    if elapsed <= 0:
        return None
    if current < prev:
        return None
    rate = (current - prev) / elapsed
    if rate < 0:
        return None
    value_store[key + "_prev"] = current
    value_store[key + "_prev_t"] = now
    return rate

def _state_name(n):
    if n == 0:
        return "OK"
    if n == 1:
        return "WARN"
    if n == 2:
        return "CRIT"
    return "UNKNOWN"

def _char_to_digit(c):
    if c == "0":
        return 0
    if c == "1":
        return 1
    if c == "2":
        return 2
    if c == "3":
        return 3
    if c == "4":
        return 4
    if c == "5":
        return 5
    if c == "6":
        return 6
    if c == "7":
        return 7
    if c == "8":
        return 8
    if c == "9":
        return 9
    return -1

def _str_to_int(s):
    if s == "":
        return 0
    v = 0
    for ch in s:
        d = _char_to_digit(ch)
        if d == -1:
            break
        v = v * 10 + d
    return v

def _to_float(v):
    if v == None:
        return None
    if type(v) == "int" or type(v) == "float":
        return float(v)
    s = v.strip()
    neg = False
    if len(s) > 0 and s[0] == "-":
        neg = True
        s = s[1:]
    body = ""
    seen_dot = False
    for ch in s:
        if ch >= "0" and ch <= "9":
            body = body + ch
        elif ch == "." and not seen_dot:
            seen_dot = True
            body = body + ch
        else:
            break
    if body == "" or body == ".":
        return None
    val = 0
    parts = body.split(".")
    if len(parts) == 2:
        ip = parts[0]
        frac = parts[1]
        val = _str_to_int(ip)
        f = 0
        for c in frac:
            f = f * 10 + _char_to_digit(c)
        denom = 1
        for _ in range(len(frac)):
            denom = denom * 10
        val = val + f / denom
    else:
        val = _str_to_int(parts[0])
    if neg:
        val = -val
    return float(val)

def _parse_oid_value_map(res, base):
    target = {}
    if res.rc != 0 or res.skipped:
        return target
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if oid.startswith(base):
            suffix = oid[len(base) + 1:]
            target[suffix] = val
    return target

def _strip_quotes(v):
    s = v.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # ---- discovery mode ----
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On",
                       host, ".1.3.6.1.4.1.9.9.171.1.2.3.1.7"], mutates=False)
        idx_remote = _parse_oid_value_map(res, ".1.3.6.1.4.1.9.9.171.1.2.3.1.7")
        res_in = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On",
                          host, ".1.3.6.1.4.1.9.9.171.1.2.3.1.19"], mutates=False)
        idx_in = _parse_oid_value_map(res_in, ".1.3.6.1.4.1.9.9.171.1.2.3.1.19")
        res_out = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On",
                           host, ".1.3.6.1.4.1.9.9.171.1.2.3.1.27"], mutates=False)
        idx_out = _parse_oid_value_map(res_out, ".1.3.6.1.4.1.9.9.171.1.2.3.1.27")

        found = []
        for idx in idx_remote:
            remote = _strip_quotes(idx_remote[idx])
            if not remote:
                continue
            if idx_in.get(idx) == None or idx_out.get(idx) == None:
                continue
            found.append({"item": remote,
                          "params": {},
                          "metrics": ["if_in_octets", "if_out_octets"]})
        return {"changed": False,
                "msg": "discovered %d VPN tunnels" % len(found),
                "data": {"discovery": found}}

    # ---- check mode ----
    item = params.get("item", "")

    res_remote = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", "-On",
                          host, ".1.3.6.1.4.1.9.9.171.1.2.3.1.7"], mutates=False)
    if res_remote.rc != 0 or res_remote.skipped:
        return {"changed": False,
                "msg": "SNMP unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    b1_remote = ".1.3.6.1.4.1.9.9.171.1.2.3.1.7"
    b1_in = ".1.3.6.1.4.1.9.9.171.1.2.3.1.19"
    b1_out = ".1.3.6.1.4.1.9.9.171.1.2.3.1.27"
    b2_in = ".1.3.6.1.4.1.9.9.171.1.3.2.1.26"
    b2_out = ".1.3.6.1.4.1.9.9.171.1.3.2.1.39"

    idx_remote = _parse_oid_value_map(res_remote, b1_remote)

    target_idx = None
    for oid_suffix in idx_remote:
        remote = _strip_quotes(idx_remote[oid_suffix])
        if remote == item:
            target_idx = oid_suffix
            break

    # state_missing / aliases from params
    state_missing = int(params.get("state", 2))
    aliases = ""
    tunnels_cfg = params.get("tunnels", [])
    for entry in tunnels_cfg:
        if len(entry) >= 3 and entry[0] == item:
            aliases = str(entry[1])
            state_missing = int(entry[2])

    if state_missing == 0 and not tunnels_cfg:
        state_missing = int(params.get("state", 2))

    if target_idx == None:
        prefix = (aliases + " ") if aliases else ""
        return {"changed": False,
                "msg": prefix + "Tunnel is missing",
                "data": {"state": _state_name(state_missing),
                         "metrics": {},
                         "details": ""}}

    g_in = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                    host, b1_in + "." + target_idx], mutates=False)
    g_out = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                     host, b1_out + "." + target_idx], mutates=False)
    if g_in.rc != 0 or g_out.rc != 0:
        return {"changed": False,
                "msg": "Could not read tunnel counters for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    p1_in = _to_float(g_in.stdout.strip())
    p1_out = _to_float(g_out.stdout.strip())
    if p1_in == None or p1_out == None:
        return {"changed": False,
                "msg": "Invalid counter value for tunnel " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    gi = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                  host, b2_in + "." + target_idx], mutates=False)
    go = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                  host, b2_out + "." + target_idx], mutates=False)
    p2_in_val = _to_float(gi.stdout.strip()) if gi.rc == 0 else None
    p2_out_val = _to_float(go.stdout.strip()) if go.rc == 0 else None

    now = ctx.time()
    store = {}
    stored = ctx.file_read("/tmp/.cmk_cisco_vpn_tunnel_store") if ctx.file_exists("/tmp/.cmk_cisco_vpn_tunnel_store") else ""
    if stored:
        decoded = json.decode(stored)
        if decoded != None and type(decoded) == "dict":
            store = decoded

    r_in = _get_rate(store, item + "_p1_in", now, p1_in)
    r_out = _get_rate(store, item + "_p1_out", now, p1_out)

    p2_rates = None
    rates_init = (r_in == None or r_out == None)
    if p2_in_val != None and p2_out_val != None:
        ri = _get_rate(store, item + "_p2_in", now, p2_in_val)
        ro = _get_rate(store, item + "_p2_out", now, p2_out_val)
        p2_rates = {"input": ri, "output": ro}
        if ri == None or ro == None:
            rates_init = True

    if rates_init:
        return {"changed": False,
                "msg": "Initializing counters for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    in_total = r_in
    out_total = r_out
    if p2_rates != None and p2_rates["input"] != None and p2_rates["output"] != None:
        in_total = r_in + p2_rates["input"]
        out_total = r_out + p2_rates["output"]

    metrics = {"if_in_octets": in_total, "if_out_octets": out_total}
    prefix = (aliases + " ") if aliases else ""
    if p2_rates != None and p2_rates["input"] != None and p2_rates["output"] != None:
        p2_line = "Phase 2: in: %s, out: %s" % (
            _networkbandwidth(p2_rates["input"]),
            _networkbandwidth(p2_rates["output"]))
    else:
        p2_line = "Phase 2 missing"

    summary = prefix + "Phase 1: in: %s, out: %s" % (
        _networkbandwidth(r_in),
        _networkbandwidth(r_out))
    details = summary + " | " + p2_line
    return {"changed": False,
            "msg": details,
            "data": {"state": "OK",
                     "metrics": metrics,
                     "details": details}}