def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base = ".1.3.6.1.4.1.9.9.832.1.24.1.3.6.1"
    col_temp = base + ".5"

    if params.get("_discover"):
        sys_desc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_desc.rc != 0 or sys_desc.rc == 127:
            return {"changed": False, "msg": "device not reachable or not installed", "data": {"discovery": []}}
        desc = sys_desc.stdout.strip()
        if not desc.startswith("IE1000"):
            return {"changed": False, "msg": "not an IE1000 device", "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1", ".5"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no temperature sensors found", "data": {"discovery": []}}

        items = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            suffix = oid[len(base) + 1:]
            idx = suffix.split(".")[0]
            items.append({
                "item": "Sensor " + idx,
                "params": {"levels": params.get("levels", [70, 80])},
                "metrics": ["temperature"],
            })
        return {"changed": False, "msg": "discovered %d sensors" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    idx = item.replace("Sensor ", "")

    get = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".5." + idx],
        mutates=False,
    )
    if get.rc != 0:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = get.stdout.strip()
    if raw == "":
        return {"changed": False, "msg": "no temperature reading for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = float(raw)
    levels = params.get("levels", [70, 80])
    warn = levels[0] if len(levels) > 0 else 70
    crit = levels[1] if len(levels) > 1 else 80

    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    return {"changed": False, "msg": "%s: %f C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}