def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid.rc == 127 or sysid.rc != 0 or sysid.stdout == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "no SNMP agent / not a UPS device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no SNMP agent / not a UPS device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysoid = sysid.stdout.strip()
    ups_oids = [
        ".1.3.6.1.4.1.232.165.3",
        ".1.3.6.1.4.1.476.1.42",
        ".1.3.6.1.4.1.534.1",
        ".1.3.6.1.4.1.935",
        ".1.3.6.1.4.1.8072.3.2.10",
        ".1.3.6.1.4.1.2254.2.5",
        ".1.3.6.1.4.1.12551.4.0",
        ".1.3.6.1.4.1.43943",
        ".1.3.6.1.4.1.4555.1.1.7",
        ".1.3.6.1.4.1.42610.1.4.4",
        ".1.3.6.1.4.1.818.1.100.1",
        ".1.3.6.1.4.1.705.1",
    ]
    is_ups = False
    for oid in ups_oids:
        if sysoid == oid:
            is_ups = True
            break
    if not is_ups:
        prefixes = [".1.3.6.1.4.1.850", ".1.3.6.1.2.1.33",
                    ".1.3.6.1.4.1.534.2", ".1.3.6.1.4.1.5491",
                    ".1.3.6.1.4.1.935", ".1.3.6.1.4.1.534.10"]
        for prefix in prefixes:
            if sysoid.startswith(prefix):
                is_ups = True
                break
    if not is_ups:
        if params.get("_discover"):
            return {"changed": False, "msg": "device is not a recognized UPS",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "device is not a recognized UPS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base_oid = ".1.3.6.1.2.1.33.1.1.5"
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    if walk.rc != 0 or walk.stdout == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "no battery temperature data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no battery temperature data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    names = {}
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(base_oid) + 1:]
        if idx == "":
            continue
        names[idx] = val

    temp_base = ".1.3.6.1.2.1.33.1.2.7"
    temps = {}
    twalk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, temp_base],
        mutates=False,
    )
    if twalk.rc == 0 and twalk.stdout != "":
        for line in twalk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(temp_base) + 1:]
            if idx == "":
                continue
            temps[idx] = val

    rows = []
    for idx in names:
        tv = temps.get(idx, "")
        if tv == "":
            continue
        t = int(tv) if tv.lstrip("-").isdigit() else 0
        if t == 0:
            continue
        rows.append((names[idx], t))

    if params.get("_discover"):
        out = []
        for nm, t in rows:
            out.append({"item": "Battery " + nm,
                        "params": {"levels": params.get("levels", (40.0, 50.0))},
                        "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d battery temperature sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    target = item[len("Battery "):] if item.startswith("Battery ") else item
    matched = None
    for nm, t in rows:
        disp = "Battery " + nm
        if disp == item:
            matched = t
            break
    if matched == None:
        return {"changed": False,
                "msg": "no battery temperature sensor item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (40.0, 50.0))
    warn = levels[0] if len(levels) > 0 else 40.0
    crit = levels[1] if len(levels) > 1 else 50.0
    state = "CRIT" if matched >= crit else ("WARN" if matched >= warn else "OK")
    return {"changed": False,
            "msg": "Temperature %s: %d C" % (item, matched),
            "data": {"state": state, "metrics": {"temperature": matched},
                     "details": "Temperature %s: %d C" % (item, matched)}}