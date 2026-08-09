def main(ctx, params):
    base = ".1.3.6.1.4.1.318.1.1.13.3.2.2.2"
    cols = ["7", "9", "11", "24", "26"]
    names = ["Rack Inlet", "Supply Air", "Return Air", "Entering Fluid", "Leaving Fluid"]
    levels = params.get("levels", (30.0, 35.0))
    warn = 30.0
    crit = 35.0
    if type(levels) == "list":
        if len(levels) >= 1:
            warn = levels[0]
        if len(levels) >= 2:
            crit = levels[1]
    elif type(levels) == "tuple":
        if len(levels) >= 1:
            warn = levels[0]
        if len(levels) >= 2:
            crit = levels[1]

    sysoid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysoid.rc != 0 or not sysoid.stdout.strip():
        return {"changed": False, "msg": "APC device not reachable (sysoid)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sysoid.stdout.startswith(".1.3.6.1.4.1.318"):
        return {"changed": False, "msg": "host is not an APC device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = {}
    for col, name in zip(cols, names):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + "." + col + ".0"], mutates=False)
        if res.rc == 0:
            v = res.stdout.strip()
            if v not in ["", "-1"]:
                f = v
                if not f.lstrip("-").isdigit() and not f.count(".") == 1:
                    continue
                parts = f.split(".")
                ok = True
                for p in parts:
                    if not p.lstrip("-").isdigit():
                        ok = False
                        break
                if ok:
                    values[name] = float(v) / 10.0

    if params.get("_discover"):
        discovery = []
        for name in names:
            if name in values:
                discovery.append({"item": name, "params": {"levels": (30.0, 35.0)}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery, "host_labels": {"cmk/apc_device": "true"}}}

    item = params.get("item", "")
    temp = values.get(item) if item != "" else None
    if temp == None:
        return {"changed": False, "msg": "no data for " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    return {"changed": False, "msg": "%s: %f C" % (item, temp), "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}