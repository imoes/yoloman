# Checkmk bvip_fans check translated to read-only Starlark for the yolo-man agent.
# Monitors Bosch VIP/BGFan tray fan speeds (RPM) via SNMP.

# OID base for the BVIP fan table.
BVIP_FANS_BASE_OID = ".1.3.6.1.4.1.3967.1.1.8.1"


def _is_int(s):
    stripped = s.strip()
    if stripped == "":
        return False
    if stripped[0] in "+-":
        return stripped[1:].isdigit() and len(stripped) > 1
    return stripped.isdigit()


def _snmp_get_fans(ctx, host, community):
    """Walk the BVIP fan table. Returns list of [index_name, rpm] or None."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, BVIP_FANS_BASE_OID + ".1"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    rows = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        value = sp[1].strip()
        idx = oid[len(BVIP_FANS_BASE_OID + ".1") + 1:]
        if idx == "":
            continue
        if not _is_int(value):
            continue
        rpm = int(value)
        rows.append([idx, rpm])
    return rows


def _sys_descr(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _is_bvip(ctx, host, community):
    descr = _sys_descr(ctx, host, community)
    lower = descr.lower()
    for marker in ["flexidome", "vip-x", "dinion", "autodome"]:
        if marker in lower:
            return True
    return False


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        if not _is_bvip(ctx, host, community):
            return {"changed": False, "msg": "host is not a BVIP device", "data": {"discovery": []}}
        rows = _snmp_get_fans(ctx, host, community)
        if rows == None or len(rows) == 0:
            return {"changed": False, "msg": "no fan entries found", "data": {"discovery": []}}
        out = []
        for row in rows:
            idx = row[0]
            rpm = row[1]
            if rpm == 0:
                continue
            suggested_lower = (rpm * 0.9, rpm * 0.8)
            out.append({
                "item": idx,
                "params": {"lower": suggested_lower},
                "metrics": ["fan_rpm"],
            })
        return {"changed": False, "msg": "discovered %d fans" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _is_bvip(ctx, host, community):
        return {
            "changed": False,
            "msg": "host is not a BVIP device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    rows = _snmp_get_fans(ctx, host, community)
    if rows == None or len(rows) == 0:
        return {
            "changed": False,
            "msg": "no fan entries found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    rpm = None
    for row in rows:
        if row[0] == item:
            rpm = row[1]
            break
    if rpm == None:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    lower = params.get("lower")
    if lower == None:
        lower = (0, 0)
    warn = lower[0]
    crit = lower[1]
    if rpm <= crit:
        state = "CRIT"
    elif rpm <= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "%s %d RPM" % (item, rpm),
        "data": {
            "state": state,
            "metrics": {"fan_rpm": rpm},
            "details": "%s: %d RPM (warn <= %d, crit <= %d)" % (item, rpm, warn, crit),
        },
    }