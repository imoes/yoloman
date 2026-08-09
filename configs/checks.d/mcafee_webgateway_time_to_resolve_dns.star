def _snmp_get(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    res = ctx.run([
        "snmpget",
        "-v" + version,
        "-c", community,
        "-Oqv",
        host,
        oid,
    ], mutates=False)
    return res

def _parse_float(val_str):
    val_str = val_str.strip()
    if val_str == "" or val_str == "noSuchObject" or val_str == "noSuchInstance":
        return None
    if val_str.startswith("-"):
        return None
    parts = val_str.split(".")
    ok = True
    for p in parts:
        if not p.isdigit():
            ok = False
            break
    if not ok:
        return None
    if len(parts) == 1:
        return float(int(parts[0]))
    int_part = int(parts[0])
    frac_part = 0
    frac_str = parts[1]
    for c in frac_str:
        frac_part = frac_part * 10 + int(c)
        frac_part = frac_part
    divisor = 1
    for _ in range(len(frac_str)):
        divisor = divisor * 10
    return float(int_part) * 1.0 + float(frac_part) / float(divisor)

def _render_timespan(val):
    if val < 1.0:
        return "%d ms" % int(val * 1000)
    elif val < 60.0:
        return "%f s" % val
    elif val < 3600.0:
        m = int(val / 60)
        s = int(val % 60)
        return "%d:%d" % (m, s)
    else:
        h = int(val / 3600)
        m = int((val % 3600) / 60)
        return "%dh %dm" % (h, m)

def main(ctx, params):
    if params.get("_discover"):
        dns_time_oid = "1.3.6.1.4.1.17283.1.1.3.1.1.4"
        res = _snmp_get(ctx, params, dns_time_oid)

        if res.rc == 127:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        val = _parse_float(res.stdout)

        if val == None or val <= 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"warn": 1.0, "crit": 5.0},
                 "metrics": ["time_to_resolve_dns"]},
            ]},
        }

    dns_time_oid = "1.3.6.1.4.1.17283.1.1.3.1.1.4"
    res = _snmp_get(ctx, params, dns_time_oid)

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpget binary not found"},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Failed to query DNS resolution time: " + res.stderr},
        }

    val_ms = _parse_float(res.stdout)

    if val_ms == None:
        return {
            "changed": False,
            "msg": "DNS resolution time not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "No DNS resolution time data available from the Web Gateway"},
        }

    val = val_ms / 1000.0

    warn = params.get("warn", 1.0)
    crit = params.get("crit", 5.0)

    state = "OK"
    if val >= crit:
        state = "CRIT"
    elif val >= warn:
        state = "WARN"

    detail = "%s (thresh up: %s/%s)" % (
        _render_timespan(val),
        str(warn),
        str(crit),
    )

    return {
        "changed": False,
        "msg": detail,
        "data": {
            "state": state,
            "metrics": {"time_to_resolve_dns": val},
            "details": detail,
        },
    }