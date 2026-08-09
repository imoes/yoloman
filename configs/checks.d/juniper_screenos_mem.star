def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real Juniper ScreenOS device via SNMP sysObjectID.
        # DETECT_JUNIPER_SCREENOS matches sysoid starting with .1.3.6.1.4.1.3224.1.
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("version", "2c")

        sys_oid = ".1.3.6.1.2.1.1.2.0"
        sysoid_res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, sys_oid],
            mutates=False,
        )

        # rc 127 -> snmp binary missing; no sysoid or prefix mismatch -> not a ScreenOS device.
        if sysoid_res.rc != 0 or sysoid_res.rc == 127:
            return {"changed": False, "msg": "no juniper screenos device found",
                    "data": {"discovery": []}}
        sysoid = sysoid_res.stdout.strip()
        if not sysoid or not sysoid.startswith(".1.3.6.1.4.1.3224.1"):
            return {"changed": False, "msg": "no juniper screenos device found",
                    "data": {"discovery": []}}

        # Fetch the two OIDs the check reads: used (.1.0) and free (.2.0) under base
        # .1.3.6.1.4.1.3224.16.2 — values are in KB already (no *1024 scaling).
        base = ".1.3.6.1.4.1.3224.16.2"
        used_oid = base + ".1.0"
        free_oid = base + ".2.0"

        used_res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, used_oid],
            mutates=False,
        )
        free_res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, free_oid],
            mutates=False,
        )

        if used_res.rc != 0 or free_res.rc != 0:
            return {"changed": False, "msg": "no juniper screenos memory data",
                    "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 memory service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": ("perc_used", (80.0, 90.0))},
                        "metrics": ["mem_used", "mem_total", "mem_free"],
                    }
                ],
                "host_labels": {"cmk/os_family": "screenos"},
            },
        }

    # ---- CHECK MODE ----
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    item = params.get("item", "")

    base = ".1.3.6.1.4.1.3224.16.2"
    used_oid = base + ".1.0"
    free_oid = base + ".2.0"

    used_res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, used_oid],
        mutates=False,
    )
    free_res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, free_oid],
        mutates=False,
    )

    if used_res.rc != 0 or free_res.rc != 0:
        msg = "juniper screenos memory not available"
        if used_res.rc == 127 or free_res.rc == 127:
            msg = "snmp tool not installed"
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used = int(used_res.stdout.strip())
    free = int(free_res.stdout.strip())
    total = used + free
    if total == 0:
        return {"changed": False, "msg": "total memory is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", ("perc_used", (80.0, 90.0)))
    warn = 80.0
    crit = 90.0
    if levels != None and type(levels) == "list" and len(levels) == 2:
        second = levels[1]
        if type(second) == "list" or type(second) == "tuple":
            if len(second) >= 1:
                warn = float(second[0])
            if len(second) >= 2:
                crit = float(second[1])

    pct = (used / total) * 100.0
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    kb_to_mb = lambda kb: kb / 1024.0
    msg = "Memory: used %d KB (%d MB), total %d KB (%d MB), %f%% used" % (
        used, kb_to_mb(used), total, kb_to_mb(total), pct)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "mem_used": used,
                "mem_total": total,
                "mem_free": free,
            },
            "details": "used %d KB, free %d KB, total %d KB (%f%%)" % (used, free, total, pct),
        },
    }