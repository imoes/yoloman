def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Probe: is this an APC device? Read sysObjectID.
        oid_sys = ".1.3.6.1.2.1.1.2.0"
        res_sys = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_sys],
            mutates=False,
        )
        if res_sys.rc != 0:
            return {"changed": False, "msg": "SNMP unreachable", "data": {"discovery": []}}
        sys_oid = res_sys.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not an APC device", "data": {"discovery": []}}

        discovery = []
        # External temp sensors: walk the name column.
        base_sensors = ".1.3.6.1.4.1.318.1.1.10.4.2.3.1"
        res_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_sensors + ".3"],
            mutates=False,
        )
        seen = {}
        if res_walk.rc == 0:
            for line in res_walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid_full, val = parts[0], parts[1].strip().strip('"')
                idx = oid_full[len(base_sensors + ".3") + 1:]
                seen[idx] = val

        for idx, name in sorted(seen.items()):
            discovery.append({
                "item": name,
                "params": {"levels": (25, 30)},
                "metrics": ["temperature"],
            })

        # Battery temperature scalar from the main APC enterprise tree.
        oid_batt_temp = ".1.3.6.1.4.1.318.1.1.1.2.2.2.0"
        res_bt = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_batt_temp],
            mutates=False,
        )
        if res_bt.rc == 0:
            val = res_bt.stdout.strip().strip('"')
            if val != "":
                discovery.append({
                    "item": "Battery",
                    "params": {"levels": (50, 60)},
                    "metrics": ["temperature"],
                })

        return {
            "changed": False,
            "msg": "discovered %d temperature items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_sensors = ".1.3.6.1.4.1.318.1.1.10.4.2.3.1"
    oid_batt_temp = ".1.3.6.1.4.1.318.1.1.1.2.2.2.0"

    reading = None
    if item == "Battery":
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_batt_temp],
            mutates=False,
        )
        if res.rc == 0:
            val = res.stdout.strip().strip('"')
            if val != "" and val.replace(".", "").replace("-", "").isdigit():
                reading = float(val)
        if reading == None:
            return {
                "changed": False,
                "msg": "no battery temperature available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        levels = (50.0, 60.0)
    else:
        # External sensor: walk the name column, find index, query the value column.
        res_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_sensors + ".3"],
            mutates=False,
        )
        idx = None
        if res_walk.rc == 0:
            for line in res_walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0]
                val = parts[1].strip().strip('"')
                if val == item:
                    idx = oid_full[len(base_sensors + ".3") + 1:]
                    break
        if idx == None:
            return {
                "changed": False,
                "msg": "no such temperature sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        res_val = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_sensors + ".5." + idx],
            mutates=False,
        )
        if res_val.rc != 0:
            return {
                "changed": False,
                "msg": "failed to read sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        val = res_val.stdout.strip().strip('"')
        if val == "" or not val.replace(".", "").replace("-", "").isdigit():
            return {
                "changed": False,
                "msg": "no temperature reading for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        reading = float(val)
        levels = (25.0, 30.0)

    # Apply Checkmk defaults if not overridden via params.
    p_levels = params.get("levels")
    if p_levels != None:
        levels = (float(p_levels[0]), float(p_levels[1]))
    warn, crit = levels[0], levels[1]

    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature %f C" % reading,
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": "levels: %s/%s C" % (warn, crit),
        },
    }