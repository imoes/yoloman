def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("version", "2c")
        detect = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host,
                          ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if detect.rc != 0:
            return {"changed": False, "msg": "SNMP unreachable", "data": {"discovery": []}}
        if "netscaler" not in (detect.stdout or "").lower():
            return {"changed": False, "msg": "not a netscaler", "data": {"discovery": []}}

        name_walk = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn",
                             host, ".1.3.6.1.4.1.5951.4.1.1.41.8.1.1"], mutates=False)
        size_walk = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn",
                             host, ".1.3.6.1.4.1.5951.4.1.1.41.8.1.2"], mutates=False)
        avail_walk = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn",
                              host, ".1.3.6.1.4.1.5951.4.1.1.41.8.1.3"], mutates=False)

        def to_map(walk_res, colbase):
            m = {}
            for line in (walk_res.stdout or "").splitlines():
                line = line.strip()
                sp = line.find(" ")
                if sp < 0:
                    continue
                oid = line[:sp]
                val = line[sp + 1:]
                idx = oid[len(colbase) + 1:]
                m[idx] = val
            return m

        colbase = ".1.3.6.1.4.1.5951.4.1.1.41.8.1"
        names = to_map(name_walk, colbase + ".1")
        sizes = to_map(size_walk, colbase + ".2")
        avail = to_map(avail_walk, colbase + ".3")

        out = []
        for idx, name in names.items():
            sz = sizes.get(idx, "0")
            size_f = float(sz)
            name_clean = name.strip().strip('"')
            if not name_clean or size_f <= 0:
                continue
            out.append({"item": name_clean, "params": {}, "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d filesystems" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    base = ".1.3.6.1.4.1.5951.4.1.1.41.8.1"

    name_walk = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, base + ".1"], mutates=False)
    if name_walk.rc != 0 and name_walk.rc != 2:
        return {"changed": False, "msg": "not a netscaler or unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = None
    for line in (name_walk.stdout or "").splitlines():
        line = line.strip()
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip().strip('"')
        if val == item:
            idx = oid.rsplit(".", 1)[-1]
            break
    if idx == None:
        return {"changed": False, "msg": "no such filesystem: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, base + ".2." + idx], mutates=False)
    avail_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, base + ".3." + idx], mutates=False)
    if size_res.rc != 0 or avail_res.rc != 0:
        return {"changed": False, "msg": "failed to read netscaler fs metrics",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    size = float(size_res.stdout)
    avail = float(avail_res.stdout)
    if size <= 0:
        return {"changed": False, "msg": item + " size unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used = size - avail
    used_percent = (used / size) * 100.0 if size > 0 else 0.0

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list":
            warn = levels[0] if len(levels) > 0 else warn
            crit = levels[1] if len(levels) > 1 else crit
        elif type(levels) == "dict":
            warn = levels.get("warn", warn)
            crit = levels.get("crit", crit)

    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
    return {"changed": False,
            "msg": "%s %d%% used" % (item, int(used_percent)),
            "data": {"state": state, "metrics": {"used_percent": used_percent}, "details": ""}}