def main(ctx, params):
    if params.get("_discover"):
        sysoid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"),
                          ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysoid.rc != 0 or ".1.3.6.1.4.1.2011.2.25.1" not in sysoid.stdout:
            return {"changed": False, "msg": "not a Huawei OSN device",
                    "data": {"discovery": [], "host_labels": {}}}
        walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.2.190"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no temperature data found",
                    "data": {"discovery": [], "host_labels": {}}}
        discovery = []
        seen = {}
        for line in walk.stdout.splitlines():
            sp = line.split()
            if len(sp) < 2:
                continue
            oid = sp[0]
            idx = oid[len(".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.2.190") + 1:]
            name_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                "-Oqv", params.get("host", "localhost"),
                                ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.6.190." + idx], mutates=False)
            name = name_res.stdout.strip() if name_res.rc == 0 else idx
            key = name
            n = 1
            while key in seen:
                n += 1
                key = name + "_" + str(n)
            seen[key] = True
            discovery.append({"item": key, "params": {"levels": (70.0, 80.0)},
                              "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "huawei_osn"}}}
    item = params.get("item", "")
    walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                    "-Oqn", params.get("host", "localhost"),
                    ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.2.190"], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "no temperature data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found_idx = None
    target_name = item.split("_")[0]
    for line in walk.stdout.splitlines():
        sp = line.split()
        if len(sp) < 2:
            continue
        oid = sp[0]
        idx = oid[len(".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.2.190") + 1:]
        name_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.6.190." + idx], mutates=False)
        name = name_res.stdout.strip() if name_res.rc == 0 else idx
        if name == item or idx == item:
            found_idx = idx
            break
    if found_idx == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-Oqv", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.2011.2.25.3.40.50.76.10.1.2.190." + found_idx], mutates=False)
    if temp_res.rc != 0:
        return {"changed": False, "msg": "could not read temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = temp_res.stdout.strip()
    temp = float(raw) / 10.0
    warn = params.get("levels", (70.0, 80.0))[0]
    crit = params.get("levels", (70.0, 80.0))[1]
    if temp >= crit or temp <= crit:
        pass
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Temperature %s: %f C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}