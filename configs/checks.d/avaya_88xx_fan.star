def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.2272.1.4.7.1.1"
    sys_oid = ".1.3.6.1.2.1.1.2.0"

    detect = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), sys_oid],
        mutates=False,
    )
    if detect.rc != 0 or detect.stdout.strip() != ".1.3.6.1.4.1.2272":
        return {"changed": False, "msg": "not an Avaya device", "data": {"discovery": [], "state": "UNKNOWN", "metrics": {}, "details": "sysObjectID does not match Avaya enterprise prefix"}}

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), base_oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no Avaya fan data", "data": {"discovery": []}}

        rows = {}
        for line in res.stdout.splitlines():
            sp = len(line) - len(line.lstrip(" "))
            oid = line.strip().split(" ", 1)[0]
            val = line.strip().split(" ", 1)[1] if " " in line.strip() else ""
            suffix = oid[len(base_oid) + 1:]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            idx = parts[0]
            col = parts[1]
            if idx not in rows:
                rows[idx] = {}
            rows[idx][col] = val

        discovery = []
        for idx in sorted(rows.keys(), key=lambda x: int(x)):
            discovery.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    idx_int = int(item)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), base_oid + ".2." + item],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no fan data for index " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "fan index " + item + " not found"}}

    fan_state = res.stdout.strip()
    fan_map = {
        "1": ("UNKNOWN", "Reported Unknown"),
        "2": ("OK", "Running"),
        "3": ("CRIT", "Down"),
    }
    entry = fan_map.get(fan_state)
    if entry == None:
        return {"changed": False, "msg": "unknown fan state: " + fan_state,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "unmapped fan state value " + fan_state}}

    state, text = entry
    return {"changed": False, "msg": "Fan " + item + " " + text,
            "data": {"state": state, "metrics": {}, "details": text}}