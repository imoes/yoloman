def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    item = params.get("item", "")

    def snmp_get(oid):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc != 0:
            return None
        return res.stdout.strip()

    def is_stormshield():
        # Check sysObjectID (.1.3.6.1.2.1.1.2.0)
        sys_obj_id = snmp_get(".1.3.6.1.2.1.1.2.0")
        if sys_obj_id == None:
            return False
        # Any of: starts with .1.3.6.1.4.1.8072, equals .1.3.6.1.4.1.11256.2.0,
        # or starts with .1.3.6.1.4.1.11256.1
        if (sys_obj_id.startswith(".1.3.6.1.4.1.8072") or
            sys_obj_id == ".1.3.6.1.4.1.11256.2.0" or
            sys_obj_id.startswith(".1.3.6.1.4.1.11256.1")):
            # Also verify basic info exists
            basic = snmp_get(".1.3.6.1.4.1.11256.1.0.1")
            if basic != None:
                return True
        return False

    if params.get("_discover"):
        if not is_stormshield():
            return {"changed": False, "msg": "no Stormshield device found", "data": {"discovery": [], "host_labels": {}}}
        metrics = ["stormshield_info"]
        entry = {"item": "", "params": {"warn": warn, "crit": crit}, "metrics": metrics}
        return {"changed": False, "msg": "discovered Stormshield Info service", "data": {"discovery": [entry]}}

    # Check mode
    if not is_stormshield():
        return {"changed": False, "msg": "no Stormshield device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base_oid = ".1.3.6.1.4.1.11256.1.0"
    oids = ["1", "2", "3", "4", "5"]
    labels = ["Model", "Version", "Serial", "SysName", "SysLanguage"]
    values = []
    for i, oid_suffix in enumerate(oids):
        val = snmp_get(base_oid + "." + oid_suffix)
        if val == None:
            return {"changed": False, "msg": "failed to fetch " + labels[i], "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        values.append(val)

    summary = "Model: %s, Version: %s, Serial: %s, SysName: %s, SysLanguage: %s" % (
        values[0], values[1], values[2], values[3], values[4]
    )
    return {"changed": False, "msg": summary, "data": {"state": "OK", "metrics": {}, "details": ""}}