def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.2.3.51.3.1.2.2.1"
        sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        descr = ""
        if sys_descr.rc == 0:
            raw = sys_descr.stdout.strip()
            if raw.startswith('"') and raw.endswith('"'):
                descr = raw[1:len(raw)-1]
            else:
                descr = raw
        if not (descr.endswith(" mips") or descr.endswith(" sh4a")):
            return {"changed": False, "msg": "not an IBM IMM", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"], mutates=False)
        discovery = []
        if res.rc == 0:
            seen = set()
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                if not oid.startswith(base + ".2."):
                    continue
                idx = oid[len(base + ".2") + 1:]
                if idx in seen:
                    continue
                seen.add(idx)
                name = parts[1]
                if name.startswith('"') and name.endswith('"'):
                    name = name[1:len(name)-1]
                discovery.append({"item": name, "params": {}, "metrics": ["volt"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.2.3.51.3.1.2.2.1"
    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"], mutates=False)
    if walk_res.rc != 0:
        return {"changed": False, "msg": "failed to walk voltage table: " + walk_res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    index = None
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        if not oid.startswith(base + ".2."):
            continue
        val = parts[1]
        if val.startswith('"') and val.endswith('"'):
            val = val[1:len(val)-1]
        if val == item:
            index = oid[len(base + ".2") + 1:]
            break
    if index == None:
        return {"changed": False, "msg": "no such voltage sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cols = {}
    for col in ["3", "6", "7", "9", "10"]:
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + col + "." + index], mutates=False)
        if r.rc != 0:
            return {"changed": False, "msg": "failed to read column " + col + ": " + r.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        cols[col] = r.stdout.strip()
    volt = float(cols["3"]) / 1000
    warn = float(cols["7"]) / 1000
    crit = float(cols["9"]) / 1000
    warn_low = float(cols["10"]) / 1000
    crit_low = float(cols["6"]) / 1000
    state = "OK"
    if volt >= crit or volt <= crit_low:
        state = "CRIT"
    elif volt >= warn or volt <= warn_low:
        state = "WARN"
    return {"changed": False, "msg": "%s: %f V" % (item, volt), "data": {"state": state, "metrics": {"volt": volt}, "details": ""}}