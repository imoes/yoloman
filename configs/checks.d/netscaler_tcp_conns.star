def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = ".1.3.6.1.4.1.5951.4.1.1.46"

    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, base_oid + ".1.0", base_oid + ".2.0"],
        mutates=False,
    )

    if probe.rc != 0:
        if probe.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "snmp query failed: %s" % probe.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    server_conns = None
    client_conns = None
    for line in probe.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_val = parts[0]
        val = None
        if oid_val.endswith(base_oid + ".1.0"):
            val = _extract_value(parts[1:])
            if val != None:
                server_conns = val
        elif oid_val.endswith(base_oid + ".2.0"):
            val = _extract_value(parts[1:])
            if val != None:
                client_conns = val

    if server_conns == None or client_conns == None:
        return {"changed": False, "msg": "no netscaler tcp connection data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"server_conns": (25000, 30000), "client_conns": (25000, 30000)},
                     "metrics": ["server_conns", "client_conns"]}
                ],
                "host_labels": {"cmk/os_family": "netscaler"},
            },
        }

    server_levels = params.get("server_conns", (25000, 30000))
    client_levels = params.get("client_conns", (25000, 30000))

    server_state, server_metric = _grade_upper(server_conns, server_levels)
    client_state, client_metric = _grade_upper(client_conns, client_levels)

    state = _worst(server_state, client_state)

    return {
        "changed": False,
        "msg": "Server: %d, Client: %d" % (server_conns, client_conns),
        "data": {
            "state": state,
            "metrics": {"server_conns": server_conns, "client_conns": client_conns},
            "details": "",
        },
    }


def _extract_value(rest):
    if len(rest) == 0:
        return None
    if len(rest) == 1:
        v = rest[0]
        if v.isdigit():
            return int(v)
        return None
    v = " ".join(rest)
    if len(rest) == 2 and rest[0] == "\"" and rest[1].endswith("\""):
        inner = rest[1][:-1]
        if inner.isdigit():
            return int(inner)
        return None
    if v.startswith("\"") and v.endswith("\"") and len(v) >= 2:
        inner = v[1:-1]
        if inner.isdigit():
            return int(inner)
        return None
    if v.isdigit():
        return int(v)
    return None


def _grade_upper(value, levels):
    if levels == None:
        return ("OK", value)
    warn = levels[0] if len(levels) >= 1 else None
    crit = levels[1] if len(levels) >= 2 else None
    if crit != None and value >= crit:
        return ("CRIT", value)
    if warn != None and value >= warn:
        return ("WARN", value)
    return ("OK", value)


def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    va = order.get(a, 3)
    vb = order.get(b, 3)
    if va >= vb:
        return a
    return b