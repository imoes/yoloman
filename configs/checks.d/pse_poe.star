def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base = "1.3.6.1.2.1.105.1.3.1.1"

    # probe: is POE present on this host?
    detect = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         "1.3.6.1.2.1.105.1.3.1.1.2"],
        mutates=False,
    )
    if detect.rc == 127:
        return {"changed": False,
                "msg": "snmpget not installed",
                "data": {"discovery": []}}
    if detect.rc != 0:
        return {"changed": False,
                "msg": "no POE present (snmp detection failed)",
                "data": {"discovery": []}}

    # walk the pethPseTable: columns 2 (poe_max), 3 (poe_status), 4 (poe_used)
    # -Oqn => "<col-OID>.<index> <value>"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False,
                "msg": "snmpwalk not installed",
                "data": {"discovery": []}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False,
                "msg": "no POE present",
                "data": {"discovery": []}}

    col_max = {}
    col_status = {}
    col_used = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(base + ".2") + 1:]
        col_max[idx] = val

    res2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"],
        mutates=False,
    )
    for line in res2.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(base + ".3") + 1:]
        col_status[idx] = val

    res3 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".4"],
        mutates=False,
    )
    for line in res3.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(base + ".4") + 1:]
        col_used[idx] = val

    indices = list(col_max.keys())

    if params.get("_discover"):
        discovery = []
        for idx in sorted(indices):
            discovery.append({"item": idx, "params": {"levels": (90.0, 95.0)},
                              "metrics": ["power_usage_percentage"]})
        return {"changed": False,
                "msg": "discovered %d POE instances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    poe_max_s = col_max.get(item)
    poe_status_s = col_status.get(item)
    poe_used_s = col_used.get(item)

    if poe_max_s == None or poe_status_s == None or poe_used_s == None:
        return {"changed": False,
                "msg": "no POE instance with index " + item + " found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    poe_max = int(poe_max_s)
    poe_used = int(poe_used_s)
    poe_status = int(poe_status_s)

    if poe_max < 0 or poe_used < 0 or poe_status not in (1, 2, 3):
        return {"changed": False,
                "msg": "Device returned faulty data: nominal power: %s, power consumption: %s, operational status: %s" % (
                    poe_max_s, poe_used_s, poe_status_s),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if poe_status == 2:
        return {"changed": False,
                "msg": "Operational status of the PSE is OFF",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if poe_status == 3:
        return {"changed": False,
                "msg": "Operational status of the PSE is FAULTY",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # poe_status == 1 (ON): grade power usage percentage against thresholds
    if poe_max > 0:
        used_pct = (float(poe_used) / float(poe_max)) * 100
    else:
        used_pct = 0.0

    levels = params.get("levels")
    if levels == None:
        warn_pct = 90.0
        crit_pct = 95.0
    else:
        warn_pct = levels[0]
        crit_pct = levels[1]

    state = "CRIT" if used_pct >= crit_pct else ("WARN" if used_pct >= warn_pct else "OK")
    return {"changed": False,
            "msg": "POE usage (%sW/%sW): %f%% used" % (str(poe_used), str(poe_max), used_pct),
            "data": {"state": state,
                     "metrics": {"power_usage_percentage": used_pct},
                     "details": ""}}