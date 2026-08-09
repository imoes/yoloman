def _snmp_get(ctx, params, oid_suffix):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                   "1.3.6.1.4.1." + oid_suffix], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


_MAP_STATES = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("OK", "OK"),
    "3": ("WARN", "degraded"),
    "4": ("CRIT", "failed"),
}


def main(ctx, params):
    if params.get("_discover"):
        sysOid = _snmp_get(ctx, params, "2.1.1.2.0")
        if sysOid == None or sysOid == "":
            return {"changed": False, "msg": "not an HP ProLiant",
                    "data": {"discovery": [], "host_labels": {}}}
        is_hp = ("8072.3.2.10" in sysOid) or ("232.9.4.10" in sysOid)
        if not is_hp and not ("311.1.1.3.1.2" in sysOid):
            return {"changed": False, "msg": "not an HP ProLiant",
                    "data": {"discovery": [], "host_labels": {}}}
        status = _snmp_get(ctx, params, "232.11.1.3.0")
        if status == None or status == "":
            return {"changed": False, "msg": "HP ProLiant MIB missing",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}],
                         "host_labels": {"cmk/hp_proliant": "yes"}}}

    status = _snmp_get(ctx, params, "232.11.1.3.0")
    firmware = _snmp_get(ctx, params, "232.11.2.14.1.1.5.0")
    serial = _snmp_get(ctx, params, "232.2.2.2.1.0")
    if status == None or status == "":
        return {"changed": False, "msg": "no HP ProLiant status available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    entry = _MAP_STATES.get(status)
    if entry == None:
        state = "UNKNOWN"
        readable = "unhandled[" + str(status) + "]"
    else:
        state = entry[0]
        readable = entry[1]
    fw = firmware if firmware != None else ""
    sn = serial if serial != None else ""
    summary = "Status: " + readable + ", Firmware: " + fw + ", S/N: " + sn
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}