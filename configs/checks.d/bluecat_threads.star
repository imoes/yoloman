def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", (2000, 4000)) or (2000, 4000)
    warn = levels[0]
    crit = levels[1]

    # Probe for the BlueCat SNMP product via sysObjectID first.
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid_res.rc != 0 or not sysid_res.stdout:
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "no BlueCat SNMP product found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no BlueCat SNMP product found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    is_bluecat = sysid_res.stdout.strip().startswith(".1.3.6.1.4.1.13315.100.200")
    if not is_bluecat:
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "no BlueCat SNMP product found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no BlueCat SNMP product found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the thread count scalar.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.4.1.13315.100.200.1.1.2.1"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "no thread data available",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no thread data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    if not raw.isdigit():
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "no thread data available",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no thread data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nthreads = int(raw)

    if params.get("_discover"):
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": levels},
                     "metrics": ["threads"]},
                ]}}

    if crit != None and nthreads >= crit:
        state = "CRIT"
        summary = "%d threads (critical at %d)" % (nthreads, crit)
    elif warn != None and nthreads >= warn:
        state = "WARN"
        summary = "%d threads (warning at %d)" % (nthreads, warn)
    else:
        state = "OK"
        summary = "%d threads" % nthreads

    return {"changed": False,
            "msg": summary,
            "data": {"state": state,
                     "metrics": {"threads": nthreads},
                     "details": ""}}