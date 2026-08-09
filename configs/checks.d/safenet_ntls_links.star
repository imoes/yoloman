def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: check if the device is a Safenet NTLS appliance
        # Detect via sysObjectID (.1.3.6.1.2.1.1.2.0)
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "not a Safenet NTLS device", "data": {"discovery": []}}
        sys_oid = sys_oid_res.stdout.strip()
        if not (sys_oid.startswith(".1.3.6.1.4.1.12383") or sys_oid.startswith(".1.3.6.1.4.1.8072")):
            return {"changed": False, "msg": "not a Safenet NTLS device", "data": {"discovery": []}}
        # Fetch the safenet_ntls section - just need the links value to confirm section exists
        links_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12383.3.1.2.3"], mutates=False)
        if links_res.rc != 0:
            return {"changed": False, "msg": "no NTLS section data", "data": {"discovery": []}}
        # Single-service check (no item)
        levels = params.get("levels", ("no_levels", None))
        return {
            "changed": False,
            "msg": "discovered NTLS Links service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels": levels}, "metrics": ["connections"]}
                ]
            },
        }

    # Check mode
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Fetch the links value (OID 3 from the safenet_ntls section)
    links_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12383.3.1.2.3"], mutates=False)
    if links_res.rc != 0:
        return {
            "changed": False,
            "msg": "no NTLS links data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed for NTLS links"},
        }
    
    links_str = links_res.stdout.strip()
    if not links_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid links value: " + links_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    links = int(links_str)
    levels = params.get("levels", ("no_levels", None))
    
    state = "OK"
    warn = None
    crit = None
    if levels != None and levels != "no_levels":
        # levels is a tuple (warn, crit) for upper levels
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
        elif len(levels) >= 1:
            warn = levels[0]
    
    if crit != None and links >= crit:
        state = "CRIT"
    elif warn != None and links >= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "%d links" % links,
        "data": {"state": state, "metrics": {"connections": links}, "details": ""},
    }