def main(ctx, params):
    if params.get("_discover"):
        # Detection: this is an HP ProCurve device (SNMP sysObjectID).
        # Probe the real thing: sysObjectID under .1.1.2.2.1.1.2.0.
        # HP ProCurve OIDs end with ".11.2.3.7.11" or ".11.2.3.7.8".
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0 or sysid.rc == 127:
            return {"changed": False, "msg": "not an HP ProCurve device",
                    "data": {"discovery": []}}
        sid = sysid.stdout.strip()
        if not (sid.endswith(".11.2.3.7.11") or sid.endswith(".11.2.3.7.8")):
            return {"changed": False, "msg": "not an HP ProCurve device",
                    "data": {"discovery": []}}

        # Verify memory OIDs are present.
        mem = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.5",
             ".1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.7"],
            mutates=False,
        )
        if mem.rc != 0 or mem.rc == 127:
            return {"changed": False, "msg": "no memory data",
                    "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"levels": ("perc_used", (80.0, 90.0))},
                     "metrics": ["mem_used", "mem_total", "mem_used_percent"]},
                ]}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    base = ".1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1"
    get = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, base + ".5", base + ".7"],
        mutates=False,
    )

    if get.rc != 0:
        if get.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "cannot query memory: " + get.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vals = get.stdout.splitlines()
    if len(vals) < 2:
        return {"changed": False, "msg": "cannot read memory values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_total = int(vals[0])
    mem_used = int(vals[1])

    levels = params.get("levels", ("perc_used", (80.0, 90.0)))
    if type(levels) == "list" and len(levels) == 2 and type(levels[0]) != "string":
        levels = ("perc_used", tuple(levels))

    warn = 80.0
    crit = 90.0
    if type(levels) == "tuple" and len(levels) == 2 and levels[0] == "perc_used":
        tup = levels[1]
        warn = tup[0]
        crit = tup[1]

    pct = 0.0
    if mem_total > 0:
        pct = (float(mem_used) / float(mem_total)) * 100.0

    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Usage: %f%% (%d/%d bytes)" % (pct, mem_used, mem_total)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"mem_used": mem_used, "mem_total": mem_total,
                                 "mem_used_percent": pct},
                     "details": ""}}