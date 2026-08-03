def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0 or sys_oid.stdout.strip() != ".1.3.6.1.4.1.8072.3.2.10":
            return {"changed": False, "msg": "no PrimeKey device found",
                    "data": {"discovery": []}}
        db = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.22408.1.1.2.1.4.118.100.98.49.1"], mutates=False)
        if db.rc != 0 or db.stdout == "":
            return {"changed": False, "msg": "PrimeKey DB usage not reachable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered PrimeKey DB Usage",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (80.0, 90.0)},
                     "metrics": ["disk_utilization"]}]}}
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    db = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.22408.1.1.2.1.4.118.100.98.49.1"], mutates=False)
    if db.rc != 0 or db.stdout == "":
        return {"changed": False,
                "msg": "no PrimeKey DB usage value reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = db.stdout.strip()
    if ":" in val:
        val = val.split(":", 1)[1].strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    usage = 0.0
    parts = val.split(".")
    ok_num = len(parts) == 1 and parts[0].lstrip("-").isdigit()
    if not ok_num and len(parts) == 2:
        ok_num = parts[0].lstrip("-").isdigit() and parts[1].isdigit()
    if ok_num:
        usage = float(val)
    else:
        return {"changed": False,
                "msg": "cannot parse PrimeKey DB usage value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if levels else 80.0
    crit = levels[1] if levels else 90.0
    state = "OK"
    if usage >= crit:
        state = "CRIT"
    elif usage >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "Disk Utilization: %f%%" % usage,
            "data": {"state": state,
                     "metrics": {"disk_utilization": usage},
                     "details": ""}}