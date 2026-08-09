def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.14823.2.2.1.1.3"
    oid_sysid = ".1.3.6.1.2.1.1.2.0"
    warn = params.get("warn", None)
    crit = params.get("crit", None)

    if params.get("_discover"):
        sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid_sysid], mutates=False)
        if sysid.rc != 0:
            return {"changed": False, "msg": "no Aruba device found", "data": {"discovery": []}}
        sysval = sysid.stdout.strip()
        if not sysval.startswith(".1.3.6.1.4.1.14823"):
            return {"changed": False, "msg": "not an Aruba device", "data": {"discovery": []}}
        val = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".1"], mutates=False)
        if val.rc != 0:
            return {"changed": False, "msg": "could not read aruba_aps OID", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": ["connections"]}]}}

    val = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".1"], mutates=False)
    if val.rc != 0:
        return {"changed": False, "msg": "no data: could not query Aruba APS", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sval = val.stdout.strip()
    if sval == "":
        return {"changed": False, "msg": "no data: empty SNMP response", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sval.isdigit():
        return {"changed": False, "msg": "no data: non-numeric SNMP response: %s" % sval, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    connected_aps = int(sval)
    state = "OK"
    if warn != None and connected_aps >= int(warn):
        state = "WARN"
    if crit != None and connected_aps >= int(crit):
        state = "CRIT"
    return {"changed": False, "msg": "Connections: %d" % connected_aps, "data": {"state": state, "metrics": {"connections": connected_aps}, "details": ""}}