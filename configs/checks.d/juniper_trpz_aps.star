def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sysOID = _snmpget(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sysOID == None:
            return {"changed": False, "msg": "not a Juniper TRILL/APS device", "data": {"discovery": []}}
        if not _sysOIDMatchesJuniper(sysOID):
            return {"changed": False, "msg": "not a Juniper TRILL/APS device", "data": {"discovery": []}}
        aps = _snmpget(ctx, host, community, ".1.3.6.1.4.1.14525.4.5.1.1.1")
        sessions = _snmpget(ctx, host, community, ".1.3.6.1.4.1.14525.4.4.1.1.4")
        if aps == None or sessions == None:
            return {"changed": False, "msg": "no APS data available", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["ap_devices_total", "total_sessions"],
                        "service_labels": {"cmk/vendor": "juniper"},
                    }
                ]
            },
        }

    item = params.get("item", "")
    aps = _snmpget(ctx, host, community, ".1.3.6.1.4.1.14525.4.5.1.1.1")
    sessions = _snmpget(ctx, host, community, ".1.3.6.1.4.1.14525.4.4.1.1.4")
    if aps == None or sessions == None:
        return {
            "changed": False,
            "msg": "no Juniper APS data available (not a target device or data unavailable)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    apsVal = _toInt(aps)
    sessVal = _toInt(sessions)
    if apsVal == None or sessVal == None:
        return {
            "changed": False,
            "msg": "invalid APS data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sysOID = _snmpget(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    node_name = ""
    if sysOID != None and _sysOIDMatchesJuniper(sysOID):
        node_name = _nodeNameForSysOID(sysOID)
    prefix = ""
    if node_name:
        prefix = "[%s] " % node_name
    return {
        "changed": False,
        "msg": "%sOnline access points: %d, Sessions: %d" % (prefix, apsVal, sessVal),
        "data": {
            "state": "OK",
            "metrics": {"ap_devices_total": float(apsVal), "total_sessions": float(sessVal)},
            "details": "",
        },
    }


def _snmpget(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val


def _toInt(v):
    if v == None:
        return None
    if v.isdigit():
        return int(v)
    return None


def _sysOIDMatchesJuniper(sysOID):
    if sysOID == None:
        return False
    return sysOID.startswith(".1.3.6.1.4.1.14525.3.1") or sysOID.startswith(".1.3.6.1.4.1.14525.3.3")


def _nodeNameForSysOID(sysOID):
    if sysOID == None:
        return ""
    if sysOID == ".1.3.6.1.4.1.14525.3.1":
        return "node1"
    if sysOID == ".1.3.6.1.4.1.14525.3.3":
        return "node2"
    return ""