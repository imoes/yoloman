def main(ctx, params):
    base = ".1.3.6.1.4.1.2011.5.25.31.1.1"
    oids = ["2.1.13", "1.1.5", "1.1.7"]
    columns = ["name", "cpu", "mem"]
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + oids[0]], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        names = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(base + "." + oids[0]) + 1:]
            names[idx] = parts[1].strip().strip('"')
        found = []
        for idx, dev_name in names.items():
            mem_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oids[2] + "." + idx], mutates=False)
            if mem_res.rc == 0 and mem_res.stdout.strip():
                found.append({"item": dev_name, "params": {"levels": [80.0, 90.0]}, "metrics": ["mem_used_percent"]})
        return {"changed": False, "msg": "discovered %d devices" % len(found), "data": {"discovery": found}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + oids[0]], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: %s" % res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_oid = None
    idx = None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx_val = oid[len(base + "." + oids[0]) + 1:]
        val = parts[1].strip().strip('"')
        if val == item:
            name_oid = oid
            idx = idx_val
            break
    if idx == None:
        return {"changed": False, "msg": "no such device: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oids[1] + "." + idx], mutates=False)
    mem_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oids[2] + "." + idx], mutates=False)
    if mem_res.rc != 0 or not mem_res.stdout.strip():
        return {"changed": False, "msg": "could not read memory for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_str = mem_res.stdout.strip()
    mem_val = float(mem_str)
    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0
    state = "CRIT" if mem_val >= crit else ("WARN" if mem_val >= warn else "OK")
    pct = "%f" % mem_val
    return {"changed": False, "msg": "Used: %s%%" % pct, "data": {"state": state, "metrics": {"mem_used_percent": mem_val}, "details": ""}}