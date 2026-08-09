def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "10", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.5.3.3"

    if params.get("_discover"):
        sys_oid = _snmp_get(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None or not sys_oid.startswith(".1.3.6.1.4.1.20246"):
            return {"changed": False, "msg": "no orion device", "data": {"discovery": [], "host_labels": {}}}
        status = _snmp_get(ctx, community, host, base + ".2")
        minutes = _snmp_get(ctx, community, host, base + ".3")
        if status == None or minutes == None:
            return {"changed": False, "msg": "orion backup not present", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}], "host_labels": {"cmk/orion_backup": "true"}}}

    status = _snmp_get(ctx, community, host, base + ".2")
    minutes = _snmp_get(ctx, community, host, base + ".3")
    if status == None or minutes == None:
        return {"changed": False, "msg": "orion backup not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    map_states = {
        "1": ("WARN", "inactive"),
        "2": ("OK", "OK"),
        "3": ("WARN", "occured"),
        "4": ("CRIT", "fail"),
    }

    state_readable = map_states.get(status, ("UNKNOWN", "unknown"))
    state, label = state_readable
    return {"changed": False, "msg": "Status: %s, Expected time: %s minutes" % (label, minutes), "data": {"state": state, "metrics": {}, "details": ""}}