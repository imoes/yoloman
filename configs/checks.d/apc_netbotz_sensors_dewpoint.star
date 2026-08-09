def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _snmpget(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    return None

def _snmpwalk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc == 0:
        return res.stdout.splitlines()
    return []

def _probe(ctx, host, community):
    # Detect APC Netbotz over SNMP via sysObjectID
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    sys_val = _snmpget(ctx, host, community, sys_oid)
    if sys_val == None:
        return None
    if not (sys_val.startswith(".1.3.6.1.4.1.5528.100.20.10") or sys_val.startswith(".1.3.6.1.4.1.52674.500")):
        return None
    # Determine which firmware base to use
    v2_base = ".1.3.6.1.4.1.5528.100.4.1.1.1"
    v50_base = ".1.3.6.1.4.1.52674.500.4.1.1.1"
    temp_col = "1.2.4.7"
    temp_oid_root = v2_base
    temp_res = _snmpwalk(ctx, host, community, v2_base + "." + temp_col)
    if not temp_res:
        temp_res = _snmpwalk(ctx, host, community, v50_base + "." + temp_col)
        if temp_res:
            temp_oid_root = v50_base
    if not temp_res:
        return None
    # Walk the dewpoint tree (column 1=label, 2=plugged_state, 4=reading, 7=?)
    # Actually the SNMPTree base is the table base, oids are 1,2,4,7
    dew_base = temp_oid_root.replace(".1.1.1", ".3.1.1")
    dew_walk = _snmpwalk(ctx, host, community, dew_base + ".1")
    dew_lines = []
    for col in ["1", "2", "4", "7"]:
        dew_lines.append(_snmpwalk(ctx, host, community, dew_base + "." + col))
    # Build dewpoint items: name (oid1), reading (oid4), plugged_in (oid2)
    items = []
    # Correlate by index
    indices = {}
    for line in dew_lines[0]:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(dew_base + ".1") + 1:]
        indices[idx] = {"name": parts[1]}
    for line in dew_lines[2]:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(dew_base + ".4") + 1:]
        if idx in indices:
            indices[idx]["reading"] = parts[1]
    for line in dew_lines[1]:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(dew_base + ".2") + 1:]
        if idx in indices:
            indices[idx]["plugged"] = parts[1]
    for idx, d in indices.items():
        if "reading" not in d:
            continue
        plugged = d.get("plugged", "1")
        if plugged == "0":
            continue
        items.append({"item": d["name"], "reading": d["reading"]})
    return {"temp_oid_root": temp_oid_root, "dewpoint": items}

def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    data = _probe(ctx, host, community)
    if data == None:
        return {"changed": False, "msg": "no APC Netbotz sensor device found", "data": {"discovery": []}}
    discovery = []
    for it in data["dewpoint"]:
        discovery.append({"item": it["item"], "params": {"levels": (18.0, 25.0), "levels_lower": (-4.0, -6.0)}, "metrics": ["dewpoint"]})
    return {"changed": False, "msg": "discovered %d dewpoint sensors" % len(discovery), "data": {"discovery": discovery}}

def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    data = _probe(ctx, host, community)
    if data == None:
        return {"changed": False, "msg": "no APC Netbotz sensor device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found = None
    for it in data["dewpoint"]:
        if it["item"] == item:
            found = it
            break
    if found == None:
        return {"changed": False, "msg": "no such dewpoint sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    reading = float(found["reading"]) / 10.0
    levels = params.get("levels", (18.0, 25.0))
    levels_lower = params.get("levels_lower", (-4.0, -6.0))
    warn, crit = levels
    lwarn, lcrit = levels_lower
    state = "OK"
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    elif reading <= lcrit:
        state = "CRIT"
    elif reading <= lwarn:
        state = "WARN"
    return {"changed": False, "msg": "Dew point %s: %f C" % (item, reading), "data": {"state": state, "metrics": {"dewpoint": reading}, "details": ""}}