def main(ctx, params):
    if params.get("_discover"):
        result = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"),
                          ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if result.rc != 0 or not result.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        sys_obj_id = result.stdout.strip()
        is_trpz = sys_obj_id.startswith(".1.3.6.1.4.1.14525.3")
        is_screenos = sys_obj_id.startswith(".1.3.6.1.4.1.3224.1")
        if not is_trpz and not is_screenos:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": ("perc_used", (80.0, 90.0))},
                     "metrics": ["mem_used", "mem_total"]}
                ]}}

    result = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-Oqv", params.get("host", "localhost"),
                      ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if result.rc != 0 or not result.stdout.strip():
        return {"changed": False, "msg": "no Juniper device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_obj_id = result.stdout.strip()
    is_trpz = sys_obj_id.startswith(".1.3.6.1.4.1.14525.3")
    is_screenos = sys_obj_id.startswith(".1.3.6.1.4.1.3224.1")
    if not is_trpz and not is_screenos:
        return {"changed": False, "msg": "no Juniper device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if is_trpz:
        used_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            ".1.3.6.1.4.1.14525.4.8.1.1.12.1"], mutates=False)
        total_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                             "-Oqv", params.get("host", "localhost"),
                             ".1.3.6.1.4.1.14525.4.8.1.1.6.1"],
                            mutates=False)
        if used_res.rc != 0 or total_res.rc != 0 or not used_res.stdout.strip() or not total_res.stdout.strip():
            return {"changed": False, "msg": "cannot read memory values from TRPZ device",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        used = int(used_res.stdout.strip()) * 1024
        total = int(total_res.stdout.strip()) * 1024
    else:
        used_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            ".1.3.6.1.4.1.3224.16.2.1.0"], mutates=False)
        free_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            ".1.3.6.1.4.1.3224.16.2.2.0"], mutates=False)
        if used_res.rc != 0 or free_res.rc != 0 or not used_res.stdout.strip() or not free_res.stdout.strip():
            return {"changed": False, "msg": "cannot read memory values from ScreenOS device",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        used = int(used_res.stdout.strip())
        free = int(free_res.stdout.strip())
        total = used + free

    levels = params.get("levels", ("perc_used", (80.0, 90.0)))
    level_type = levels[0] if (type(levels) == "list" and len(levels) > 0) else "perc_used"
    warn = 80.0
    crit = 90.0
    if level_type == "perc_used" and type(levels) == "list" and len(levels) > 1:
        lvl_vals = levels[1]
        if type(lvl_vals) == "list" and len(lvl_vals) >= 2:
            warn = lvl_vals[0]
            crit = lvl_vals[1]

    perc_used = (used / total * 100.0) if total > 0 else 0.0
    if perc_used >= crit:
        state = "CRIT"
    elif perc_used >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Used: %f MB (%f%%), Total: %f MB" % (used / 1024.0, perc_used, total / 1024.0)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"mem_used": used, "mem_total": total, "mem_used_percent": perc_used},
                     "details": ""}}