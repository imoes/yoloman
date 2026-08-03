def _snmp_get_oid_value(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0 or not res.stdout:
        return None
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val

def _snmp_get_int(ctx, community, host, oid):
    val = _snmp_get_oid_value(ctx, community, host, oid)
    if val == None:
        return None
    return int(val) if val.isdigit() else None

def _snmp_get_float(ctx, community, host, oid):
    val = _snmp_get_oid_value(ctx, community, host, oid)
    if val == None:
        return None
    try_val = float(val) if (val.lstrip("-").replace(".", "", 1).isdigit()) else None
    return try_val

def _snmpwalk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return []
    if res.rc != 0 or not res.stdout:
        return []
    out = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        out.append((parts[0], parts[1].strip()))
    return out

def _fetch_fan(ctx, community, host, index):
    base = ".1.3.6.1.4.1.2.3.51.2.2.6.1.1"
    present = _snmp_get_int(ctx, community, host, base + ".1." + index)
    if present == None:
        return None
    status = _snmp_get_oid_value(ctx, community, host, base + ".2." + index)
    if status == None:
        return None
    fancount = _snmp_get_oid_value(ctx, community, host, base + ".3." + index)
    if fancount == None:
        return None
    speedperc = _snmp_get_int(ctx, community, host, base + ".4." + index)
    if speedperc == None:
        return None
    rpm = _snmp_get_float(ctx, community, host, base + ".5." + index)
    if rpm == None:
        return None
    ctrlstate = _snmp_get_oid_value(ctx, community, host, base + ".6." + index)
    if ctrlstate == None:
        return None
    extra = _snmp_get_oid_value(ctx, community, host, base + ".7." + index)
    if extra == None:
        return None
    return {
        "index": index,
        "present": str(present),
        "status": status,
        "fancount": fancount,
        "speedperc": speedperc,
        "rpm": rpm,
        "ctrlstate": ctrlstate,
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base = ".1.3.6.1.4.1.2.3.51.2.2.6.1.1"

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed", "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no blade powerfan data", "data": {"discovery": [], "host_labels": {}}}

        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            index = oid[len(base + ".1"):]
            if not index or not oid.startswith(base + ".1."):
                continue
            fan = _fetch_fan(ctx, community, host, index)
            if fan == None:
                continue
            if fan["present"] == "1" and fan["index"]:
                discovery.append({
                    "item": fan["index"],
                    "params": {},
                    "metrics": ["perc", "rpm"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    fan = _fetch_fan(ctx, community, host, item)
    if fan == None:
        return {
            "changed": False,
            "msg": "Fan not found or not present: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Fan not present"},
        }

    if fan["present"] != "1":
        return {
            "changed": False,
            "msg": "Fan not present",
            "data": {"state": "CRIT", "metrics": {}, "details": "Fan not present"},
        }

    warn = params.get("warn", 50)
    crit = params.get("crit", 40)
    speedperc = fan["speedperc"]
    state = "OK"
    if speedperc <= crit:
        state = "CRIT"
    elif speedperc <= warn:
        state = "WARN"

    rpm = fan["rpm"]
    rpm_state = "OK"
    rpm_warn = params.get("rpm_warn")
    rpm_crit = params.get("rpm_crit")
    if rpm_warn != None and rpm_crit != None:
        if rpm <= rpm_crit:
            rpm_state = "CRIT"
        elif rpm <= rpm_warn:
            rpm_state = "WARN"

    overall_state = "OK"
    for s in [state, rpm_state]:
        if s == "CRIT":
            overall_state = "CRIT"
        elif s == "WARN" and overall_state != "CRIT":
            overall_state = "WARN"
    if fan["status"] != "1":
        overall_state = "CRIT"
    if fan["ctrlstate"] != "1":
        overall_state = "CRIT"

    detail_lines = []
    detail_lines.append("Speed: %s%%" % speedperc)
    detail_lines.append("RPM: %s" % rpm)
    detail_lines.append("Status: %s" % ("OK" if fan["status"] == "1" else "not OK"))
    detail_lines.append("Controller state: %s" % ("OK" if fan["ctrlstate"] == "1" else "not OK"))

    return {
        "changed": False,
        "msg": "Speed: %s%%, RPM: %s" % (speedperc, rpm),
        "data": {
            "state": overall_state,
            "metrics": {"perc": speedperc, "rpm": rpm},
            "details": "\n".join(detail_lines),
        },
    }