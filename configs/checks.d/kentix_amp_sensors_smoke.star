def main(ctx, params):
    is_discover = params.get("_discover")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", [1.0, 5.0])
    item = params.get("item", "")

    base = ".1.3.6.1.4.1.37954.1"
    col_smoke = base + ".1.2.7.5"

    if is_discover:
        walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_smoke], mutates=False)
        if walk_res.rc == 127 or walk_res.rc != 0:
            return {"changed": False, "msg": "host not reachable or snmpwalk not installed", "data": {"discovery": []}}
        discovery = []
        indexes = []
        for line in walk_res.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) < 2:
                continue
            oid, value = parts[0], parts[1]
            idx = oid[len(col_smoke) + 1:]
            if idx == "":
                continue
            indexes.append(idx)
            discovery.append({"item": idx, "metrics": ["smoke_perc"]})
        return {"changed": False, "msg": "discovered %d smoke sensors" % len(discovery), "data": {"discovery": discovery}}

    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    get_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col_smoke + "." + item], mutates=False)
    if get_res.rc == 127 or get_res.rc != 0:
        return {"changed": False, "msg": "smoke sensor %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_str = get_res.stdout.strip()
    if not val_str or not val_str.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid smoke value for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    smoke = int(val_str)
    warn = levels[0]
    crit = levels[1]
    state = "CRIT" if smoke >= crit else ("WARN" if smoke >= warn else "OK")
    pct = smoke
    return {"changed": False, "msg": "Smoke Detector %s: %d%%" % (item, pct), "data": {"state": state, "metrics": {"smoke_perc": pct}, "details": ""}}