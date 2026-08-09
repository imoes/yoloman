def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.14823.2.2.1.1.1.9.1"
        col_desc = base_oid + ".2"
        col_val = base_oid + ".3"
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_desc], mutates=False)
        if walk.rc != 0 or not walk.stdout.strip():
            return {"changed": False, "msg": "no aruba cpu data", "data": {"discovery": []}}
        names = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            val = parts[1]
            index = oid[len(col_desc):]
            if len(index) > 0 and index[0] == ".":
                index = index[1:]
            names[index] = val
        out = []
        for index in names:
            val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_val + "." + index], mutates=False)
            if val_res.rc != 0 or not val_res.stdout.strip():
                continue
            v = val_res.stdout.strip()
            v_clean = _safe_float(v)
            if v_clean == None:
                continue
            out.append({"item": names[index], "params": {"levels": [80.0, 90.0]}, "metrics": ["cpu_util"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.14823.2.2.1.1.1.9.1"
    col_desc = base_oid + ".2"
    col_val = base_oid + ".3"
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_desc], mutates=False)
    if walk.rc != 0 or not walk.stdout.strip():
        return {"changed": False, "msg": "no aruba cpu data: snmpwalk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found_index = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1]
        if val != item:
            continue
        index = oid[len(col_desc):]
        if len(index) > 0 and index[0] == ".":
            index = index[1:]
        found_index = index
        break
    if found_index == None:
        return {"changed": False, "msg": "no such cpu item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_val + "." + found_index], mutates=False)
    if val_res.rc != 0 or not val_res.stdout.strip():
        return {"changed": False, "msg": "no cpu util value for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    v = val_res.stdout.strip()
    util = _safe_float(v)
    if util == None:
        return {"changed": False, "msg": "cannot parse cpu util: " + v, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", [80.0, 90.0])
    warn = 80.0
    crit = 90.0
    if type(levels) == "list" or type(levels) == "tuple":
        if len(levels) >= 1:
            warn = float(levels[0])
        if len(levels) >= 2:
            crit = float(levels[1])
    state = "OK"
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    return {"changed": False, "msg": "CPU utilization %s: %f%%" % (item, util), "data": {"state": state, "metrics": {"cpu_util": util}, "details": ""}}

def _safe_float(s):
    s = s.strip()
    if not s:
        return None
    neg = False
    body = s
    if s[0] == "-":
        neg = True
        body = s[1:]
    if len(body) == 0:
        return None
    parts = body.split(".", 1)
    if len(parts) > 2:
        return None
    for p in parts:
        if len(p) == 0:
            return None
        if not p.isdigit():
            return None
    f = float(s)
    if neg:
        f = -f
    return f