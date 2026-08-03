def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    sysoid_oid = ".1.3.6.1.2.1.1.2.0"

    # ---- discover which device family is present via sysObjectID ----
    probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sysoid_oid], mutates=False)
    if probe.rc != 0 or not probe.stdout:
        return {"changed": False, "msg": "no AKCP device found on " + host,
                "data": {"discovery": [], "host_labels": {}}}

    sysoid = probe.stdout.strip().split(":")[-1].strip()
    is_sp2plus = sysoid.startswith(".1.3.6.1.4.1.3854.3") or sysoid.startswith("1.3.6.1.4.1.3854.3")
    is_exp = sysoid.startswith(".1.3.6.1.4.1.3854.1") or sysoid.startswith("1.3.6.1.4.1.3854.1")
    if not (is_sp2plus or is_exp):
        return {"changed": False, "msg": "no AKCP device found on " + host,
                "data": {"discovery": [], "host_labels": {}}}

    # ---- choose the table to walk ----
    if is_sp2plus:
        base = ".1.3.6.1.4.1.3854.3.5.4.1"
        desc_col = "2"
        status_col = "6"
        online_col = "8"
    else:
        base = ".1.3.6.1.4.1.3854.1.2.2.1.18.1"
        desc_col = "1"
        status_col = "3"
        online_col = "5"

    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + desc_col],
                    mutates=False)
    if walk.rc != 0 or not walk.stdout:
        return {"changed": False, "msg": "no AKCP drycontact data on " + host,
                "data": {"discovery": [], "host_labels": {}}}

    rows = []  # list of {"desc":..., "index":...}
    for line in walk.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.split(None, 1)
        if len(sp) != 2:
            continue
        oid_full, desc = sp[0], sp[1].strip().strip('"')
        idx = oid_full[len(base + "." + desc_col) + 1:]
        rows.append({"desc": desc, "index": idx})

    # ---- discovery ----
    if params.get("_discover"):
        services = []
        for r in rows:
            # need to confirm online == 1 for discovery
            g = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                         base + "." + online_col + "." + r["index"]], mutates=False)
            if g.rc == 0 and g.stdout.strip().split(":")[-1].strip() == "1":
                services.append({"item": r["desc"], "params": {},
                                 "metrics": []})
        return {"changed": False,
                "msg": "discovered %d dry contacts" % len(services),
                "data": {"discovery": services, "host_labels": {}}}

    # ---- check one item ----
    target = None
    for r in rows:
        if r["desc"] == item:
            target = r
            break
    if target == None:
        return {"changed": False, "msg": "no such dry contact: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_g = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                        base + "." + status_col + "." + target["index"]], mutates=False)
    online_g = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                        base + "." + online_col + "." + target["index"]], mutates=False)

    if status_g.rc != 0 or online_g.rc != 0:
        return {"changed": False, "msg": "dry contact data not reachable for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = status_g.stdout.strip().split(":")[-1].strip()
    online = online_g.stdout.strip().split(":")[-1].strip()

    states = {
        "1": (2, "no status"),
        "7": (2, "sensor error"),
        "8": (2, "output low"),
        "9": (2, "output high"),
    }

    if online != "1":
        infotext = "Sensor is offline"
        st = 2
    elif status == "2":
        st = 0
        infotext = "Drycontact OK"
    elif status == "4":
        st = 2
        infotext = "Drycontact on Error"
    elif status == "6":
        st = 2
        infotext = "Drycontact on Error"
    elif status in states:
        st, infotext = states[status]
    else:
        st = 2
        infotext = "unknown status: " + status

    state_map = {0: "OK", 1: "WARN", 2: "CRIT"}
    verdict = state_map.get(st, "UNKNOWN")

    return {"changed": False, "msg": item + " " + infotext,
            "data": {"state": verdict, "metrics": {},
                     "details": "status=%s online=%s" % (status, online)}}