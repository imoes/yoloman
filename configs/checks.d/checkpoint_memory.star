def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no checkpoint device found",
                    "data": {"discovery": [], "host_labels": {}}}

        sys_oid_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        sys_oid = sys_oid_res.stdout.strip() if sys_oid_res.rc == 0 else ""
        sys_desc_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        sys_desc = sys_desc_res.stdout.strip() if sys_desc_res.rc == 0 else ""

        is_checkpoint = (sys_oid.startswith(".1.3.6.1.4.1.2620") or
                         ("cp" in sys_desc) or sys_desc.startswith("IPSO ") or
                         ("cpx" in sys_desc and "Linux" in sys_desc))

        fw_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.1.21.0"],
            mutates=False,
        )
        fw_name = fw_res.stdout.strip() if fw_res.rc == 0 else ""
        gaia_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.6.5.1.0"],
            mutates=False,
        )
        gaia_name = gaia_res.stdout.strip() if gaia_res.rc == 0 else ""

        is_detected = is_checkpoint and (fw_name == "firewall" or gaia_name == "Gaia")
        if not is_detected:
            return {"changed": False, "msg": "no checkpoint device found",
                    "data": {"discovery": [], "host_labels": {}}}

        return {"changed": False,
                "msg": "discovered 1 Memory System service",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": ("perc_used", (80.0, 90.0))},
                     "metrics": ["memory_used"]},
                ], "host_labels": {"cmk/os_family": "checkpoint"}}}

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.6.7.4.3"],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no checkpoint memory data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.6.7.4.3.0"],
        mutates=False,
    )
    avail_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.6.7.4.4.0"],
        mutates=False,
    )

    if total_res.rc != 0 or avail_res.rc != 0:
        return {"changed": False, "msg": "could not fetch checkpoint memory values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_total = int(total_res.stdout.strip())
    mem_avail = int(avail_res.stdout.strip())
    mem_used = mem_total - mem_avail

    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        warn = levels[1]
        crit = levels[2] if len(levels) > 2 else levels[1]
    else:
        warn = 80.0
        crit = 90.0

    used_perc = (float(mem_used) / float(mem_total) * 100.0) if mem_total > 0 else 0.0
    state = "OK"
    if used_perc >= crit:
        state = "CRIT"
    elif used_perc >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Usage: %f%%" % used_perc,
            "data": {"state": state,
                     "metrics": {"memory_used": mem_used},
                     "details": ""}}