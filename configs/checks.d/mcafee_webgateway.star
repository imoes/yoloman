def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.1230.2.7.2.1.2"], mutates=False)
        if res.rc == 127 or res.rc == 1:
            res_sky = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 ".1.3.6.1.4.1.59732.2.7.2.1.2"], mutates=False)
            if res_sky.rc == 127 or res_sky.rc == 1:
                return {"changed": False, "msg": "no McAfee/Skyhigh Web Gateway found via SNMP",
                        "data": {"discovery": []}}
            base = ".1.3.6.1.4.1.59732.2.7.2.1"
        else:
            base = ".1.3.6.1.4.1.1230.2.7.2.1"
        return {"changed": False, "msg": "discovered Web gateway statistics",
                "data": {"discovery": [
                    {"item": "", "params": {"infections": (0, 0),
                                            "connections_blocked": (0, 0)},
                     "metrics": ["infections_rate", "connections_blocked_rate"]}
                ]}}
        return {"changed": False, "msg": "Web gateway present", "data": {"discovery": [
            {"item": "", "params": {"infections": (0, 0), "connections_blocked": (0, 0)},
             "metrics": ["infections_rate", "connections_blocked_rate"]}
        ]}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res_m = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.1230.2.7.2.1.2"], mutates=False)
    base_m = ".1.3.6.1.4.1.1230.2.7.2.1"
    res_s = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.59732.2.7.2.1.2"], mutates=False)
    base_s = ".1.3.6.1.4.1.59732.2.7.2.1"

    base = None
    if res_m.rc == 0:
        base = base_m
    elif res_s.rc == 0:
        base = base_s
    else:
        return {"changed": False,
                "msg": "no McAfee/Skyhigh Web Gateway found via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    inf_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".2"], mutates=False)
    blk_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".5"], mutates=False)

    infections = None
    connections_blocked = None
    if inf_res.rc == 0 and inf_res.stdout.strip().isdigit():
        infections = int(inf_res.stdout.strip())
    if blk_res.rc == 0 and blk_res.stdout.strip().isdigit():
        connections_blocked = int(blk_res.stdout.strip())

    prev = {}
    if infections != None:
        prev["infections"] = infections
    if connections_blocked != None:
        prev["connections_blocked"] = connections_blocked

    metrics = {}
    states = []
    for key, val, mname, levels in [
        ("infections", infections, "infections_rate",
         params.get("infections", (0, 0))),
        ("connections_blocked", connections_blocked, "connections_blocked_rate",
         params.get("connections_blocked", (0, 0))),
    ]:
        if val == None:
            states.append((mname, "UNKNOWN"))
            continue
        warn, crit = levels[0], levels[1]
        state = "OK"
        if crit > 0 and val >= crit:
            state = "CRIT"
        elif warn > 0 and val >= warn:
            state = "WARN"
        metrics[mname] = val
        states.append((mname, state))

    worst = "OK"
    for _, st in states:
        if st == "CRIT":
            worst = "CRIT"
            break
        if st == "WARN" and worst != "CRIT":
            worst = "WARN"
        if st == "UNKNOWN" and worst == "OK":
            worst = "UNKNOWN"

    details = "Infections: %s, Connections blocked: %s" % (
        str(infections) if infections != None else "n/a",
        str(connections_blocked) if connections_blocked != None else "n/a")

    return {"changed": False,
            "msg": details,
            "data": {"state": worst, "metrics": metrics, "details": ""}}