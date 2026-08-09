def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        sysOid = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if sysOid.rc == 127:
            return {"changed": False, "msg": "snmp not installed", "data": {"discovery": []}}
        if sysOid.rc != 0 or base not in sysOid.stdout:
            return {"changed": False, "msg": "not a Liebert device", "data": {"discovery": []}}
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", "-On", params.get("host", "localhost"), base,
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        items = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            suffix = oid[len(base):]
            sub = suffix.split(".")
            if len(sub) >= 4 and sub[0] == "10" and sub[1] == "1" and sub[2] == "2" and sub[3] == "1" and val:
                name = val.strip().strip('"')
                items[name] = True
        if len(items):
            out = []
            for name in sorted(items):
                out.append({"item": name, "params": {"levels": (8, 12)}, "metrics": ["pressure"]})
            return {"changed": False, "msg": "discovered %d compressors" % len(out),
                    "data": {"discovery": out}}
        return {"changed": False, "msg": "no compressors", "data": {"discovery": []}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    nameOid = base + ".10.1.2.1.5266"
    valOidBase = base + ".20.1.2.1.5266"
    unitOidBase = base + ".30.1.2.1.5266"
    sysOid = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    if sysOid.rc == 127:
        return {"changed": False, "msg": "snmp not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysOid.rc != 0 or base not in sysOid.stdout:
        return {"changed": False, "msg": "not a Liebert device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    walkRes = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", "-On", params.get("host", "localhost"), nameOid,
    ], mutates=False)
    if walkRes.rc != 0 or not walkRes.stdout:
        return {"changed": False, "msg": "no compressor names found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    foundIdx = None
    for line in walkRes.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        suffix = oid[len(nameOid):]
        if val.strip().strip('"') == item:
            foundIdx = suffix
            break
    if foundIdx == None:
        return {"changed": False, "msg": "no such compressor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    valRes = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), valOidBase + "." + foundIdx,
    ], mutates=False)
    unitRes = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), unitOidBase + "." + foundIdx,
    ], mutates=False)
    if valRes.rc != 0 or unitRes.rc != 0:
        return {"changed": False, "msg": "failed to read compressor values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = 0.0
    if valRes.stdout.strip().isdigit():
        value = float(valRes.stdout.strip())
    unit = unitRes.stdout.strip().strip('"')
    levels = params.get("levels", (8, 12))
    warn = levels[0]
    crit = levels[1]
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "Head pressure: %s %f %s" % (state, value, unit),
            "data": {"state": state, "metrics": {"pressure": value},
                     "details": "Head pressure %f %s" % (value, unit)}}