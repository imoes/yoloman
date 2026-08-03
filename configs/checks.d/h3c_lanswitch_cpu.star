def _genitem(item):
    cpuid = int(item)
    if cpuid < 256:
        switchid = 1
        cputype = "Slot"
        cpunum = cpuid
    elif cpuid >= 65536:
        switchid = cpuid // 65536
        cputype = "CPU"
        cpunum = cpuid % 65536
    else:
        switchid = 1
        cputype = "Unknown"
        cpunum = cpuid
    return "Switch %d %s %d" % (switchid, cputype, cpunum)


def main(ctx, params):
    if params.get("_discover"):
        sysDescr = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0",
        ], mutates=False)
        if sysDescr.rc != 0:
            return {"changed": False, "msg": "host is not an H3C/3Com device",
                    "data": {"discovery": [], "host_labels": {}}}
        descr = sysDescr.stdout.strip()
        if "3com" not in descr.lower():
            return {"changed": False, "msg": "host is not an H3C/3Com device",
                    "data": {"discovery": [], "host_labels": {}}}

        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.43.45.1.6.1.1.1.3",
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no CPU data found",
                    "data": {"discovery": []}}

        out = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            base = ".1.3.6.1.4.1.43.45.1.6.1.1.1.3"
            idx = oid[len(base) + 1:]
            out.append({"item": _genitem(idx), "params": {"levels": [50, 75]},
                        "metrics": ["usage"]})
        return {"changed": False, "msg": "discovered %d CPU items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    levels = params.get("levels", (50, 75))
    if type(levels) == "list":
        warn = int(levels[0])
        crit = int(levels[1])
    else:
        warn = int(levels[0])
        crit = int(levels[1])

    walk = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.43.45.1.6.1.1.1.3",
    ], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "no CPU data found on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.43.45.1.6.1.1.1.3"
    util = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(base) + 1:]
        val = parts[1]
        if _genitem(idx) == item:
            util = int(val)
            break

    if util == None:
        return {"changed": False, "msg": item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    infotext = "average usage was %d%% over last 5 minutes." % util
    if util > crit:
        state = "CRIT"
    elif util > warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {"usage": util}, "details": ""}}