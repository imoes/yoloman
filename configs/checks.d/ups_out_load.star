_UPS_SYSOIDS = [
    ".1.3.6.1.4.1.232.165.3",
    ".1.3.6.1.4.1.476.1.42",
    ".1.3.6.1.4.1.534.1",
    ".1.3.6.1.4.1.935",
    ".1.3.6.1.4.1.8072.3.2.10",
    ".1.3.6.1.4.1.2254.2.5",
    ".1.3.6.1.4.1.12551.4.0",
    ".1.3.6.1.4.1.4555.1.1.7",
    ".1.3.6.1.4.1.42610.1.4.4",
    ".1.3.6.1.2.1.33",
    ".1.3.6.1.4.1.534.2",
    ".1.3.6.1.4.1.5491",
    ".1.3.6.1.4.1.705.1",
    ".1.3.6.1.4.1.818.1.100.1",
    ".1.3.6.1.4.1.850",
]

_OID_BASE = ".1.3.6.1.2.1.33.1.4.4.1"
_COL_POWER = "2"
_COL_VOLTAGE = "5"

def _int_or_zero(value):
    if value == "" or value == None:
        return 0
    return int(value)

def _is_ups(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    sysoid = res.stdout.strip()
    for known in _UPS_SYSOIDS:
        if sysoid == known or sysoid.startswith(known + "."):
            return True
    return False

def _walk_phases(ctx, host, community):
    col_oid = _OID_BASE + "." + _COL_POWER
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    phases = {}
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid_full, power_val = sp[0], sp[1]
        idx = oid_full[len(col_oid) + 1:]
        if idx == "":
            continue
        vres = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_BASE + "." + _COL_VOLTAGE + "." + idx],
            mutates=False,
        )
        voltage = _int_or_zero(vres.stdout.strip()) if vres.rc == 0 else 0
        phases[idx] = (_int_or_zero(power_val), voltage)
    return phases

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", (85, 90))

    is_ups = _is_ups(ctx, host, community)
    if is_ups != True:
        return {"changed": False, "msg": "not a UPS (no matching sysObjectID)",
                "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        phases = _walk_phases(ctx, host, community)
        discovery = []
        for idx, (power, voltage) in phases.items():
            if voltage:
                discovery.append({
                    "item": idx,
                    "params": {"levels": levels},
                    "metrics": ["out_load"],
                })
        return {"changed": False,
                "msg": "discovered %d phases" % len(discovery),
                "data": {"discovery": discovery,
                         "host_labels": {"cmk/ups": "true"}}}

    item = params.get("item", "")
    phases = _walk_phases(ctx, host, community)
    if item not in phases:
        return {"changed": False,
                "msg": "Phase %s not found in SNMP output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    power, voltage = phases[item]
    warn = levels[0]
    crit = levels[1]
    if power >= crit:
        state = "CRIT"
    elif power >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "load %f%%" % power,
            "data": {"state": state,
                     "metrics": {"out_load": power},
                     "details": "Voltage: %dV" % voltage}}