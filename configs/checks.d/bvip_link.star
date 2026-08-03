def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysDescr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysDescr.rc != 0:
            return {"changed": False, "msg": "bvip not detected (no sysDescr)", "data": {"discovery": []}}
        descr = sysDescr.stdout.strip()
        detected = False
        for marker in ["flexidome", "vip-x", "dinion", "autodome"]:
            if descr.find(marker) != -1:
                detected = True
                break
        if not detected:
            return {"changed": False, "msg": "bvip not detected (sysDescr mismatch)", "data": {"discovery": []}}
        link_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.3967.1.5.1.8.1"],
            mutates=False,
        )
        if link_res.rc != 0:
            return {"changed": False, "msg": "bvip link OID unreachable", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"ok_states": [0, 4, 5], "warn_states": [7], "crit_states": [1, 2, 3]}, "metrics": []}
                ]
            },
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.3967.1.5.1.8.1"],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "bvip link data ungatherable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw or not raw.isdigit():
        return {"changed": False, "msg": "bvip link value not numeric: %s" % raw, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    link_status = int(raw)
    states = {
        0: "No Link",
        1: "10 MBit - HalfDuplex",
        2: "10 MBit - FullDuplex",
        3: "100 Mbit - HalfDuplex",
        4: "100 Mbit - FullDuplex",
        5: "1 Gbit - FullDuplex",
        7: "Wifi",
    }
    ok_states = params.get("ok_states", [0, 4, 5])
    warn_states = params.get("warn_states", [7])
    crit_states = params.get("crit_states", [1, 2, 3])
    if link_status in ok_states:
        state = "OK"
    elif link_status in crit_states:
        state = "CRIT"
    elif link_status in warn_states:
        state = "WARN"
    else:
        state = "UNKNOWN"
    label = states.get(link_status, "Not Implemented (%d)" % link_status)
    return {
        "changed": False,
        "msg": "1: State: %s" % label,
        "data": {"state": state, "metrics": {}, "details": ""},
    }