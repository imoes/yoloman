def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    use_desc = params.get("use_sensor_description", False)
    levels = params.get("levels", None)
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    if levels != None and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    if warn == None:
        warn = 0.0
    if crit == None:
        crit = 0.0

    oid_phase = "1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    oid_desc = "1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"

    def snmp_get_scalar(oid):
        res = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return None
        return res.stdout.strip()

    def snmp_walk(oid):
        res = ctx.run(
            ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return []
        out = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2:
                out.append((parts[0], parts[1]))
        return out

    sysdesc = snmp_get_scalar("1.3.6.1.2.1.1.1.0")
    if sysdesc == None or not sysdesc.startswith("Rittal LCP"):
        if params.get("_discover") == True:
            return {"changed": False, "msg": "no Rittal LCP device found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no Rittal LCP device found at " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover") == True:
        rows = snmp_walk(oid_phase)
        discovery = []
        for oid, val in rows:
            idx = oid[len(oid_phase) + 1:]
            desc = snmp_get_scalar(oid_desc + "." + idx)
            if use_desc:
                name = "phase-" + idx + " " + (desc or "")
            else:
                name = idx
            discovery.append({
                "item": name,
                "params": {"_item_key": idx, "warn": warn, "crit": crit,
                           "use_sensor_description": use_desc},
                "metrics": ["phase"],
            })
        return {"changed": False,
                "msg": "discovered %d phase inputs" % len(discovery),
                "data": {"discovery": discovery,
                         "host_labels": {"cmk/os_family": "rittal_lcp"}}}

    item = params.get("item", "")
    key = params.get("_item_key", item)
    val_str = snmp_get_scalar(oid_phase + "." + key)
    if val_str == None:
        return {"changed": False,
                "msg": "no phase sensor found for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    try_val = val_str.strip().strip('"')
    value = float(try_val) if (try_val and _is_number(try_val)) else 0.0
    state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
    return {
        "changed": False,
        "msg": "Input %s: %s %f" % (item, state, value),
        "data": {"state": state, "metrics": {"phase": value}, "details": ""},
    }

def _is_number(s):
    if s == "":
        return False
    if s[0] in ("+", "-"):
        s = s[1:]
    if s == "":
        return False
    has_digit = False
    has_dot = False
    for ch in s:
        if ch >= "0" and ch <= "9":
            has_digit = True
        elif ch == "." and not has_dot:
            has_dot = True
        else:
            return False
    return has_digit