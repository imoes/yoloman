# Checkmk check: enterasys_lsnat -> LSNAT Bindings (read-only SNMP translation)
# Translated for the yolo-man Starlark runtime. Never mutates the system.

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "5", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None, res
    return res.stdout.strip(), res

def _sys_object_id(ctx, host, community):
    # .1.3.6.1.2.1.1.2.0 is sysObjectID.0
    val, res = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if val == None:
        return None, res
    # -Oqv on an OID-typed value prints the dotted OID string, e.g. ".1.3.6.1.4.1.5624.2.1.1"
    return val, res

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the real thing: sysObjectID must be Enterasys, and the
        # binding OID must exist. Absence of the product -> empty discovery.
        sysid, _ = _sys_object_id(ctx, host, community)
        if sysid == None:
            return {"changed": False, "msg": "device not reachable or not Enterasys",
                    "data": {"discovery": []}}
        if not sysid.startswith(".1.3.6.1.4.1.5624.2.1"):
            return {"changed": False, "msg": "sysObjectID is not Enterasys",
                    "data": {"discovery": []}}
        # Verify the LSNAT binding object exists.
        binding, bres = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.5624.1.2.74.1.1.5.0")
        if binding == None:
            return {"changed": False, "msg": "no LSNAT bindings object",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered LSNAT Bindings",
                "data": {"discovery": [
                    {"item": "", "params": {"current_bindings": None},
                     "metrics": ["current_bindings"]},
                ]}}

    item = params.get("item", "")
    # Single-service check: item must be "".
    if item != "":
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Re-establish identity for check mode too (absence -> UNKNOWN, not OK).
    sysid, _ = _sys_object_id(ctx, host, community)
    if sysid == None or not sysid.startswith(".1.3.6.1.4.1.5624.2.1"):
        return {"changed": False, "msg": "not an Enterasys device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val, res = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.5624.1.2.74.1.1.5.0")
    if val == None:
        return {"changed": False, "msg": "LSNAT bindings OID not available: " + (res.stderr or ""),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # -Oqv prints the bare integer for INTEGER-typed OIDs.
    v = val.strip()
    n = int(v) if v.lstrip("-").isdigit() else 0
    detail = v

    raw_levels = params.get("current_bindings")
    warn = None
    crit = None
    t = type(raw_levels)
    if t == "list" or t == "tuple":
        if len(raw_levels) >= 1:
            warn = raw_levels[0]
        if len(raw_levels) >= 2:
            crit = raw_levels[1]
    elif t == "dict":
        warn = raw_levels.get("warn")
        crit = raw_levels.get("crit")

    state = "OK"
    if warn != None and crit != None and n >= crit:
        state = "CRIT"
    elif warn != None and n >= warn:
        state = "WARN"

    msg = "Current bindings: %s" % detail
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"current_bindings": n}, "details": msg}}