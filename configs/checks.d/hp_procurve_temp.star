def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: the device must be an HP ProCurve switch,
    # detected via the sysObjectID prefix .1.3.6.1.4.1.11.2.3.7.11
    sysid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                         host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid_res.rc != 0 or not sysid_res.stdout.startswith(".1.3.6.1.4.1.11.2.3.7.11"):
        return {"changed": False, "msg": "no HP ProCurve device found",
                "data": {"discovery": []}}

    if params.get("_discover"):
        # Fetch system name (oid .2) and current temperature (oid .3)
        name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                            host, ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.2.0"],
                           mutates=False)
        temp_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                            host, ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.3.0"],
                           mutates=False)
        if name_res.rc != 0 or temp_res.rc != 0:
            return {"changed": False, "msg": "discovery: SNMP query failed",
                    "data": {"discovery": []}}
        item = name_res.stdout.strip()
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": item, "params": {"warn": 70, "crit": 80},
                     "metrics": ["temperature"]}]}}

    item = params.get("item", "")
    # Fetch current temperature (oid .3) for the item
    raw_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                       host, ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.3.0"],
                      mutates=False)
    if raw_res.rc != 0:
        return {"changed": False, "msg": "no HP ProCurve temperature data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = raw_res.stdout.strip()
    if not raw:
        return {"changed": False, "msg": "no HP ProCurve temperature data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # raw looks like "21C"
    digits = raw[:-1]
    unit = raw[-1]
    temp = int(digits) if digits.isdigit() else 0
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    return {"changed": False,
            "msg": "Temperature %d%s" % (temp, unit.upper()),
            "data": {"state": state,
                     "metrics": {"temperature": temp},
                     "details": ""}}