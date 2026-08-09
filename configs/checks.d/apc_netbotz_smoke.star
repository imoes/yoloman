def _fetch_smoke_sensors(ctx, host, community):
    sensors = {}
    base = ".1.3.6.1.4.1.318.1.1.10.4.7.2.1"
    cols = ["1", "2", "3", "5"]
    for col in cols:
        full_oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_oid],
            mutates=False,
        )
        if res.skipped or res.rc != 0:
            return None
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid, value = sp[0], sp[1]
            idx = oid[len(full_oid) + 1:]
            row = sensors.setdefault(idx, {})
            row[col] = value

    result = []
    for idx in sorted(sensors.keys()):
        row = sensors[idx]
        if "1" not in row or "2" not in row or "3" not in row or "5" not in row:
            continue
        result.append(row)
    return result


def _detect_apc(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.skipped or res.rc != 0:
        return False
    return res.stdout.lower().find("apc") != -1


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _detect_apc(ctx, host, community):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "host is not an APC device",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "host is not an APC device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "host is not an APC device"},
        }

    sensors = _fetch_smoke_sensors(ctx, host, community)
    if sensors == None:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "failed to fetch smoke sensor table",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "failed to fetch smoke sensor table",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "failed to fetch smoke sensor table"},
        }

    if params.get("_discover"):
        discovery = []
        for row in sensors:
            item = "%s %s/%s" % (row["3"], row["1"], row["2"])
            discovery.append({"item": item, "params": {}, "metrics": ["smoke_state"]})
        return {
            "changed": False,
            "msg": "discovered %d smoke sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    target = None
    for row in sensors:
        candidate = "%s %s/%s" % (row["3"], row["1"], row["2"])
        if candidate == item:
            target = row
            break

    if target == None:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "sensor not found"},
        }

    raw_state = int(target["5"])
    if raw_state == 1:
        state = "CRIT"
        summary = "Smoke detected"
        metric_val = 1
    elif raw_state == 2:
        state = "OK"
        summary = "No smoke detected"
        metric_val = 2
    else:
        state = "UNKNOWN"
        summary = "State Unknown"
        metric_val = 3

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {"smoke_state": metric_val}, "details": summary},
    }