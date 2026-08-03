def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            "-t", "5", "-r", "1", host, ".1.3.6.1.2.1.1.2.0"
        ], mutates=False)
        sysoid = res.stdout.strip() if res.rc == 0 else ""
        if sysoid == "" or not sysoid.startswith(".1.3.6.1.4.1.2011.2.25.1"):
            return {"changed": False, "msg": "host is not a Huawei OSN device", "data": {"discovery": []}}
        wres = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            "-t", "5", "-r", "1", host, ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1"
        ], mutates=False)
        rows = []
        if wres.rc == 0:
            for line in wres.stdout.splitlines():
                s = line.strip()
                if s == "":
                    continue
                sp = s.find(" ")
                if sp == -1:
                    continue
                rows.append((s[:sp], s[sp + 1:]))
        base = ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1"
        items = {}
        for oid, val in rows:
            suffix = oid[len(base) + 1:].lstrip(".")
            if suffix == "":
                continue
            items.setdefault(val, {})
            items[val]["name"] = val
        wres2 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            "-t", "5", "-r", "1", host, ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.2"
        ], mutates=False)
        if wres2.rc == 0:
            for line in wres2.stdout.splitlines():
                s = line.strip()
                if s == "":
                    continue
                sp = s.find(" ")
                if sp == -1:
                    continue
                oid = s[:sp]
                val = s[sp + 1:]
                idx = oid[len(".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.2") + 1:]
                items.setdefault(idx, {})
                items[idx]["power"] = val
        discovery = []
        for k, d in items.items():
            name = d.get("name", k)
            p = d.get("power")
            if p == None or p == "":
                continue
            pi = int(p) if p.lstrip("-").isdigit() else None
            if pi == None:
                continue
            discovery.append({"item": name, "params": {"levels": (700, 730)}, "metrics": ["power"]})
        return {"changed": False, "msg": "discovered %d power units" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        "-t", "5", "-r", "1", host, ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    sysoid = res.stdout.strip() if res.rc == 0 else ""
    if sysoid == "" or not sysoid.startswith(".1.3.6.1.4.1.2011.2.25.1"):
        return {"changed": False, "msg": "host is not a Huawei OSN device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    wres = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn",
            "-t", "5", "-r", "1", host, ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.1"
    ], mutates=False)
    names = {}
    if wres.rc == 0:
        for line in wres.stdout.splitlines():
            s = line.strip()
            if s == "":
                continue
            sp = s.find(" ")
            if sp == -1:
                continue
            oid = s[:sp]
            val = s[sp + 1:]
            idx = oid[len(".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.1") + 1:]
            names[idx] = val
    wres2 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn",
            "-t", "5", "-r", "1", host, ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.2"
    ], mutates=False)
    powers = {}
    if wres2.rc == 0:
        for line in wres2.stdout.splitlines():
            s = line.strip()
            if s == "":
                continue
            sp = s.find(" ")
            if sp == -1:
                continue
            oid = s[:sp]
            val = s[sp + 1:]
            idx = oid[len(".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1.2") + 1:]
            powers[idx] = val
    reading = None
    found = False
    for idx in names.keys():
        nm = names[idx]
        if nm == item:
            found = True
            p = powers.get(idx)
            if p == None or p == "":
                break
            if not p.lstrip("-").isdigit():
                break
            reading = int(p)
            break
    if not found:
        return {"changed": False, "msg": "no power unit found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if reading == None:
        return {"changed": False, "msg": "no power reading for: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (700, 730))
    warn = levels[0]
    crit = levels[1]
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Current reading: %d W" % reading, "data": {"state": state, "metrics": {"power": reading}, "details": ""}}