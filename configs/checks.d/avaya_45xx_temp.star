def main(ctx, params):
    base = ".1.3.6.1.4.1.45.1.6.3.7.1.1.5"
    sys_oid = ".1.3.6.1.2.1.1.2.0"

    # --- discovery: probe for the real thing first ---
    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), sys_oid],
            mutates=False,
        )
        if sys_res.rc != 0 or not sys_res.stdout:
            return {"changed": False, "msg": "not an Avaya 45xx device", "data": {"discovery": []}}

        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), base + ".5"],
            mutates=False,
        )
        if walk_res.rc != 0 or not walk_res.stdout:
            return {"changed": False, "msg": "no temperature sensors found",
                    "data": {"discovery": []}}

        out = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(base) + 1:]
            out.append({"item": idx, "params": {"levels": (55.0, 60.0)},
                        "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(out),
                "data": {"discovery": out}}

    # --- check mode: grade one sensor ---
    item = params.get("item", "")
    if not item:
        return {"changed": False,
                "msg": "no temperature sensor item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (55.0, 60.0))
    warn = levels[0] if type(levels) == "tuple" and len(levels) >= 1 else 55.0
    crit = levels[1] if type(levels) == "tuple" and len(levels) >= 2 else 60.0

    get_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + ".5." + item],
        mutates=False,
    )

    if get_res.rc != 0 or not get_res.stdout:
        return {"changed": False,
                "msg": "no temperature sensor found for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = get_res.stdout.strip()
    # strip leading "INTEGER: " type tag if present (shouldn't with -Oqv, but guard)
    idx = raw.find(": ")
    if idx != -1:
        raw = raw[idx + 2:].strip().strip('"')

    val = raw
    if not val.lstrip("-").isdigit():
        return {"changed": False,
                "msg": "invalid temperature value '%s' for item %s" % (raw, item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = float(int(val)) / 2.0
    state = "CRIT" if temperature >= crit else ("WARN" if temperature >= warn else "OK")

    return {"changed": False,
            "msg": "Temperature Chassis %s: %f C" % (item, temperature),
            "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}}