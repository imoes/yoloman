def _snmp_get_oid(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "" or out == "No Such Instance" or out == "No Such Object":
        return None
    return out

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.strip().split("\n"):
        line = line.strip()
        if line == "" or line.startswith("No more names"):
            continue
        parts = line.split(" ", 1)
        if len(parts) == 2:
            lines.append((parts[0], parts[1]))
    return lines

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", params.get("hostname", "localhost"))
        sys_oid = _snmp_get_oid(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None or not sys_oid.startswith(".1.3.6.1.4.1.332.11.6"):
            return {"changed": False, "msg": "host is not a Kentix device", "data": {"discovery": []}}
        tables = [
            (".1.3.6.1.4.1.37954.2.1.1", "LAN"),
            (".1.3.6.1.4.1.37954.3.1.1", "Rack"),
        ]
        items = []
        seen = {}
        for base, group in tables:
            rows = _snmp_walk(ctx, community, host, base)
            grouped = {}
            for oid, value in rows:
                suffix = oid[len(base) + 1:]
                parts = suffix.split(".")
                if len(parts) < 3:
                    continue
                idx = parts[0]
                col = parts[1]
                grouped.setdefault(idx, {})[col] = value
            for idx, cols in grouped.items():
                col1 = cols.get("1", "").strip('"')
                if col1 != "":
                    key = group + " " + col1
                else:
                    key = group + " " + idx
                if key not in seen:
                    seen[key] = True
                    items.append({"item": key, "params": {"warn": 30, "crit": 35}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(items), "data": {"discovery": items}}
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", params.get("hostname", "localhost"))
    warn = params.get("warn", 30)
    crit = params.get("crit", 35)
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = item.split(" ", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    group_name = parts[0]
    sensor_name = parts[1]
    base = None
    for b, g in [(".1.3.6.1.4.1.37954.2.1.1", "LAN"), (".1.3.6.1.4.1.37954.3.1.1", "Rack")]:
        if g == group_name:
            base = b
    if base == None:
        return {"changed": False, "msg": "unknown group: %s" % group_name, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rows = _snmp_walk(ctx, community, host, base)
    grouped = {}
    for oid, value in rows:
        suffix = oid[len(base) + 1:]
        parts2 = suffix.split(".")
        if len(parts2) < 3:
            continue
        idx = parts2[0]
        col = parts2[1]
        grouped.setdefault(idx, {})[col] = value
    found_idx = None
    for idx, cols in grouped.items():
        col1 = cols.get("1", "").strip('"')
        if col1 == sensor_name:
            found_idx = idx
            break
        if idx == sensor_name:
            found_idx = idx
            break
    if found_idx == None:
        return {"changed": False, "msg": "sensor not found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cols = grouped[found_idx]
    value_str = cols.get("2", "")
    lower_str = cols.get("3", "")
    if value_str == "":
        return {"changed": False, "msg": "no temperature reading for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    try_val = value_str.strip()
    if not try_val.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid temperature value for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    reading = float(try_val) / 10.0
    if lower_str.strip().lstrip("-").isdigit():
        lower_warn = float(lower_str.strip())
    else:
        lower_warn = None
    state = "OK"
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    if lower_warn != None and reading <= lower_warn:
        state = "CRIT"
    return {"changed": False, "msg": "%s %f C" % (item, reading), "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}