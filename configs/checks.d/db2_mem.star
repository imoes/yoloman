def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["db2", "list", "running", "databases"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "discovered 0 db2 instances",
                    "data": {"discovery": []}}
        res2 = ctx.run(["db2", "get_dbmemory"], mutates=False)
        if res2.rc == 127 or res2.rc != 0 or not res2.stdout:
            return {"changed": False, "msg": "discovered 0 db2 instances",
                    "data": {"discovery": []}}
        discovery = []
        seen = []
        for line in res2.stdout.splitlines():
            f = line.split()
            if len(f) >= 2 and f[0] == "Instance":
                inst = f[1]
                if inst not in seen:
                    seen.append(inst)
                    discovery.append({"item": inst,
                                      "params": {"levels_lower": [10.0, 5.0]},
                                      "metrics": ["mem_used"]})
        return {"changed": False,
                "msg": "discovered %d db2 instances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    levels_lower = params.get("levels_lower", [10.0, 5.0])
    warn = levels_lower[0] if len(levels_lower) > 0 else 10.0
    crit = levels_lower[1] if len(levels_lower) > 1 else 5.0

    res = ctx.run(["db2", "get_dbmemory"], mutates=False)
    if res.rc == 127 or res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "db2 not accessible / no instance data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.split("\n")
    parsed = []
    for line in lines:
        if line.strip():
            parsed.append(line.split())

    in_block = False
    limit = None
    usage = None
    for l in parsed:
        if len(l) >= 2 and l[0] == "Instance" and l[1] == item:
            in_block = True
        elif in_block:
            if len(l) >= 2 and l[-1].lower() in ("kb", "mb"):
                unit = l[-1].lower()
                num = int(l[-2]) if l[-2].isdigit() else 0
                if unit == "kb":
                    value = num * 1024
                else:
                    value = num * 1024 * 1024
            else:
                if len(l) >= 2:
                    value = int(l[-2]) if l[-2].isdigit() else 0
                else:
                    continue
            if limit == None:
                limit = value
            else:
                usage = value
                break

    if limit == None or usage == None:
        return {"changed": False,
                "msg": "no memory data for instance %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    perc_free = (limit - usage) / limit * 100.0
    state = "OK"
    if perc_free <= crit:
        state = "CRIT"
    elif perc_free <= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Max %s, Used %d B, Free %f%%" % (
                _render_bytes(limit), usage, perc_free),
            "data": {"state": state,
                     "metrics": {"mem_used": usage, "mem_free_percent": perc_free},
                     "details": ""}}

def _render_bytes(b):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    u = 0
    val = float(b)
    while val >= 1024.0 and u < len(units) - 1:
        val = val / 1024.0
        u = u + 1
    if u == 0:
        return "%d %s" % (b, units[u])
    return "%f %s" % (val, units[u])