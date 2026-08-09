def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "not a CASA device", "data": {"discovery": []}}
        sys_oid = res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.20858.2."):
            return {"changed": False, "msg": "not a CASA device", "data": {"discovery": []}}

        walk1 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.20858.10.31.1.1.1"],
            mutates=False,
        )
        if walk1.rc != 0:
            return {"changed": False, "msg": "no fan data", "data": {"discovery": []}}

        walk2 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.20858.10.33.1.4.1"],
            mutates=False,
        )
        if walk2.rc != 0:
            return {"changed": False, "msg": "no fan status data", "data": {"discovery": []}}

        speeds = {}
        for line in walk1.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.20858.10.31.1.1.1") + 1:]
            speeds[idx] = parts[1].strip()

        statuses = {}
        for line in walk2.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.20858.10.33.1.4.1") + 1:]
            statuses[idx] = parts[1].strip()

        discovery = []
        for idx in speeds:
            if idx in statuses:
                discovery.append(
                    {
                        "item": idx,
                        "params": {},
                        "metrics": ["speed"],
                    }
                )
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    walk1 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.20858.10.31.1.1.1"],
        mutates=False,
    )
    if walk1.rc != 0:
        return {
            "changed": False,
            "msg": "no fan data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    walk2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.20858.10.33.1.4.1"],
        mutates=False,
    )
    if walk2.rc != 0:
        return {
            "changed": False,
            "msg": "no fan status data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    speeds = {}
    for line in walk1.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        idx = oid[len(".1.3.6.1.4.1.20858.10.31.1.1.1") + 1:]
        speeds[idx] = parts[1].strip()

    statuses = {}
    for line in walk2.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        idx = oid[len(".1.3.6.1.4.1.20858.10.33.1.4.1") + 1:]
        statuses[idx] = parts[1].strip()

    if item not in speeds:
        return {
            "changed": False,
            "msg": "Fan %s not found in snmp output" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    speed = speeds[item]
    fan_status = statuses.get(item, "")

    state = "UNKNOWN"
    summary = ""
    metrics = {}

    if fan_status == "1":
        state = "OK"
        summary = "%s RPM" % speed
    elif fan_status == "3":
        state = "WARN"
        summary = "%s RPM, running over threshold (!)" % speed
    elif fan_status == "2":
        state = "WARN"
        summary = "%s RPM, running under threshold (!)" % speed
    elif fan_status == "0":
        state = "UNKNOWN"
        summary = "%s RPM, unknown fan status (!)" % speed
    elif fan_status == "4":
        state = "CRIT"
        summary = "FAN Failure (!!)"
    else:
        state = "UNKNOWN"
        summary = "unknown fan status (!)"

    if speed.isdigit():
        metrics["speed"] = int(speed)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }