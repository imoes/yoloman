def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.3854.2.3.14.1"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"],
            mutates=False,
        )
        # not present / not installed -> empty discovery
        if walk.rc != 0:
            return {"changed": False, "msg": "no akcp_exp_smoke device found",
                    "data": {"discovery": []}}
        index_to_desc = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(base + ".2") + 1:]
            index_to_desc[idx] = parts[1].strip().strip('"')
        discovery = []
        for idx, desc in index_to_desc.items():
            status = _snmp_get(ctx, params, host, community, base + ".6." + idx)
            online = _snmp_get(ctx, params, host, community, base + ".8." + idx)
            if online == "1":
                discovery.append({"item": desc, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d smoke sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.3854.2.3.14.1"
    # find the sensor whose description matches item
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"],
        mutates=False,
    )
    if walk.rc != 0:
        return {"changed": False, "msg": "no akcp_exp_smoke device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx = ""
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        candidate_idx = oid[len(base + ".2") + 1:]
        desc = parts[1].strip().strip('"')
        if desc == item:
            idx = candidate_idx
            break
    if idx == "":
        return {"changed": False, "msg": "no such smoke sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = _snmp_get(ctx, params, host, community, base + ".6." + idx)
    online = _snmp_get(ctx, params, host, community, base + ".8." + idx)
    relay_states = {
        "1": (2, "no status"),
        "2": (0, "normal"),
        "4": (2, "high critical"),
        "6": (2, "low critical"),
        "7": (2, "sensor error"),
        "8": (2, "relay on"),
        "9": (0, "relay off"),
    }
    state = "UNKNOWN"
    summary = "unknown state"
    if online != "1":
        state = "CRIT"
        summary = "sensor is offline"
    elif status in relay_states:
        st, name = relay_states[status]
        if st == 0:
            state = "OK"
        elif st == 1:
            state = "WARN"
        else:
            state = "CRIT"
        summary = "State: %s" % name
    return {"changed": False, "msg": item + " - " + summary,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _snmp_get(ctx, params, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return ""
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val