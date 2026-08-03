# ===== translated Starlark check module: bintec_sensors_fan =====
# SNMP-based fan sensor check for Bintec devices.
# Reads fan sensor RPM values from the SNMP table at .1.3.6.1.4.1.272.4.17.7.1.1.1
# and grades them against lower threshold levels (warn, crit).
# Discovery item = sensor_descr (the display name from OID column 3).
# Other column OIDs are re-queried by the numeric table index.

def _snmp_get(ctx, params, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), oid],
        mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _snmp_walk(ctx, params, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), oid],
        mutates=False)
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        rows.append((line[:sp], line[sp + 1:]))
    return rows

def _walk_column(ctx, params, base, col):
    oid = base + "." + col
    rows = _snmp_walk(ctx, params, oid)
    out = []
    for line_oid, val in rows:
        idx = line_oid[len(oid) + 1:]
        out.append((idx, val))
    return out

def _fetch_sensors(ctx, params):
    base = ".1.3.6.1.4.1.272.4.17.7.1.1.1"
    cols = {"descr": "3", "type": "4", "value": "5"}
    descr_rows = _walk_column(ctx, params, base, cols["descr"])
    type_rows = _walk_column(ctx, params, base, cols["type"])
    value_rows = _walk_column(ctx, params, base, cols["value"])
    by_idx = {}
    for idx, val in descr_rows:
        by_idx[idx] = {"descr": val, "type": None, "value": None}
    for idx, val in type_rows:
        if idx in by_idx:
            by_idx[idx]["type"] = val
    for idx, val in value_rows:
        if idx in by_idx:
            by_idx[idx]["value"] = val
    return by_idx

def main(ctx, params):
    base = ".1.3.6.1.4.1.272.4.17.7.1.1.1"
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    sys_val = _snmp_get(ctx, params, sys_oid)
    if sys_val == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "bintec device not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sys_val.startswith(".1.3.6.1.4.1.272.4"):
        if params.get("_discover"):
            return {"changed": False, "msg": "not a bintec device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "not a bintec device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        by_idx = _fetch_sensors(ctx, params)
        disc = []
        for idx in sorted(by_idx.keys()):
            s = by_idx[idx]
            if s["type"] == "2" and s["descr"] != None and s["value"] != None:
                disc.append({"item": s["descr"],
                             "params": {"lower": (2000, 1000)},
                             "metrics": ["rpm"]})
        return {"changed": False, "msg": "discovered %d fan sensors" % len(disc),
                "data": {"discovery": disc}}

    item = params.get("item", "")
    by_idx = _fetch_sensors(ctx, params)
    sensor = None
    for idx in by_idx:
        s = by_idx[idx]
        if s["descr"] == item and s["type"] == "2":
            sensor = s
            break
    if sensor == None or sensor["value"] == None:
        return {"changed": False, "msg": "fan sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rpm = int(sensor["value"])
    lower = params.get("lower", (2000, 1000))
    warn = lower[0]
    crit = lower[1]
    if rpm <= crit:
        state = "CRIT"
    elif rpm <= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "%s fan at %d rpm" % (item, rpm),
            "data": {"state": state, "metrics": {"rpm": rpm}, "details": ""}}