def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.11.1.2"
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        rows = []
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            idx = oid[len(base_oid) + 1:]
            if idx == "":
                continue
            rows.append(idx)
        items = []
        for nr in range(1, len(rows) + 1):
            items.append({
                "item": str(nr),
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items},
        }
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.11.1.2"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no fan data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        idx = oid[len(base_oid) + 1:]
        if idx == "":
            continue
        rows.append(idx)
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    nr = int(item)
    if nr < 1 or nr > len(rows):
        return {
            "changed": False,
            "msg": "no such fan: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    idx = rows[nr - 1]
    col_oid = base_oid[: base_oid.rfind(".2")] + ".2"
    get_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, col_oid + "." + idx],
        mutates=False,
    )
    if get_res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query fan state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw = get_res.stdout.strip().strip('"')
    if not raw.isdigit():
        return {
            "changed": False,
            "msg": "invalid fan state: %s" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    fan_state = int(raw)
    fan_states = {
        0: "has no status",
        1: "not running",
        2: "running",
    }
    label = fan_states.get(fan_state, "unknown (%s)" % fan_state)
    state = "OK" if fan_state == 2 else "CRIT"
    return {
        "changed": False,
        "msg": "Fan " + label,
        "data": {"state": state, "metrics": {}, "details": ""},
    }