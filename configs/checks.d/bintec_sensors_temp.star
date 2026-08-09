def main(ctx, params):
    # --- discovery mode ---
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.272.4.17.7.1.1.1"
        oids = ["2", "3", "4", "5", "7"]
        # First verify the device is present via the sysObjectID detection OID.
        det = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if det.rc != 0:
            return {"changed": False, "msg": "no SNMP response from host",
                    "data": {"discovery": [], "host_labels": {}}}
        sysid = det.stdout.strip()
        if not sysid.startswith(".1.3.6.1.4.1.272.4"):
            return {"changed": False, "msg": "not a bintec device",
                    "data": {"discovery": []}}
        # Walk the full sensor table (columns 2,3,4,5,7 -> descr,type,value,unit + id).
        # We walk column 2 (sensor description, index = row index) and column 3 (type)
        # to discover temperature sensors (type == "1").
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             base + ".2", base + ".3"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "failed to walk bintec sensor table",
                    "data": {"discovery": []}}
        rows = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            idx = oid[len(base) + 1:]
            col = oid[len(base) + 1:][:1]
            # determine column by comparing full oid prefix
            if oid == base + ".2." + idx:
                rows.setdefault(idx, {})["descr"] = value
            elif oid == base + ".3." + idx:
                rows.setdefault(idx, {})["type"] = value
        discovery = []
        for idx in sorted(rows.keys()):
            info = rows[idx]
            if info.get("type") != "1":
                continue
            descr = info.get("descr", "")
            if descr == "":
                continue
            discovery.append({
                "item": descr,
                "params": {"levels": [35.0, 40.0]},
                "metrics": ["temperature"],
            })
        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    # --- check mode ---
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.272.4.17.7.1.1.1"

    # Verify device identity.
    det = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if det.rc != 0:
        return {"changed": False, "msg": "no SNMP response from host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysid = det.stdout.strip()
    if not sysid.startswith(".1.3.6.1.4.1.272.4"):
        return {"changed": False, "msg": "not a bintec device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk sensor description + type columns to find the target item's index.
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         base + ".2", base + ".3"],
        mutates=False,
    )
    if walk.rc != 0:
        return {"changed": False, "msg": "failed to walk sensor table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        idx = oid[len(base) + 1:]
        if oid == base + ".2." + idx and value == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "Sensor not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}

    # Read the temperature value for the matched index (column 5).
    val = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".5." + target_idx],
        mutates=False,
    )
    if val.rc != 0:
        return {"changed": False, "msg": "failed to read sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = val.stdout.strip()
    reading = 0
    if raw.lstrip("-").isdigit():
        reading = int(raw)

    levels = params.get("levels", [35.0, 40.0])
    warn = levels[0] if len(levels) > 0 else 35.0
    crit = levels[1] if len(levels) > 1 else 40.0
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Temperature %s is at %s C" % (item, str(reading)),
            "data": {"state": state, "metrics": {"temperature": reading},
                     "details": ""}}