def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "not installed or not reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_oid = res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.2334"):
            return {"changed": False,
                    "msg": "device is not a Packeteer system",
                    "data": {"discovery": [], "host_labels": {}}}
        res2 = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.2334.2.1.5.8", ".1.3.6.1.4.1.2334.2.1.5.10"],
            mutates=False)
        if res2.rc == 127 or res2.rc != 0:
            return {"changed": False, "msg": "not installed or not reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        lines = res2.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False,
                    "msg": "no power supply data available",
                    "data": {"discovery": [], "host_labels": {}}}
        ps0 = lines[0].strip()
        ps1 = lines[1].strip()
        items = []
        if ps0 != "":
            items.append({"item": "0", "params": {},
                          "metrics": ["ps_status_0"]})
        if ps1 != "":
            items.append({"item": "1", "params": {},
                          "metrics": ["ps_status_1"]})
        return {"changed": False,
                "msg": "discovered %d power supplies" % len(items),
                "data": {"discovery": items, "host_labels": {}}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "not installed or not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = res.stdout.strip()
    if not sys_oid.startswith(".1.3.6.1.4.1.2334"):
        return {"changed": False,
                "msg": "device is not a Packeteer system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item == "0":
        oid = ".1.3.6.1.4.1.2334.2.1.5.8"
    else:
        oid = ".1.3.6.1.4.1.2334.2.1.5.10"
    res2 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                   mutates=False)
    if res2.rc != 0:
        return {"changed": False, "msg": "no power supply data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    ps_status = res2.stdout.strip()
    if ps_status == "1":
        msg = "Power Supply %s okay" % item
        state = "OK"
    else:
        msg = "Power Supply %s not okay" % item
        state = "CRIT"
    metrics = {"ps_status_%s" % item: 1 if ps_status == "1" else 0}
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}