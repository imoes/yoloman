def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsioperf"], mutates=False)
        if res.rc != 0 or res.rc == 127:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        items = []
        seen = {}
        for line in res.stdout.splitlines():
            fields = line.split()
            if len(fields) < 4:
                continue
            name = fields[0]
            if name not in seen:
                seen[name] = True
                items.append({"item": name, "params": {}, "metrics": ["read", "write"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsioperf"], mutates=False)
    if res.rc != 0 or res.rc == 127:
        return {"changed": False,
                "msg": "svcinfo not available or lsioperf failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = None
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0] == item:
            value = fields[1]
            break
    if value == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pct = float(value)
    warn = params.get("warn", 90)
    crit = params.get("crit", 95)
    state = "CRIT" if pct >= crit else ("WARN" if pct >= warn else "OK")
    return {"changed": False,
            "msg": "CPU utilization Total %s %d%%" % (item, pct),
            "data": {"state": state, "metrics": {"cpu_util": pct}, "details": ""}}