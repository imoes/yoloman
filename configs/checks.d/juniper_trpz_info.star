def _snmp_get_str(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the Juniper Trapeze chassis via the enterprise OID of the
    # trapz chassis (DETECT_JUNIPER_TRPZ = sysObjectID startswith .1.3.6.1.4.1.14525.3)
    sys_oid = _snmp_get_str(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None or not sys_oid.startswith(".1.3.6.1.4.1.14525.3"):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 juniper trapz chassis",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "juniper trapz chassis not found (sysObjectID is not a trapz device)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the serial (.1.3.6.1.4.1.14525.4.2.1.1) and firmware version
    # (.1.3.6.1.4.1.14525.4.2.1.4)
    serial = _snmp_get_str(ctx, host, community, ".1.3.6.1.4.1.14525.4.2.1.1")
    version = _snmp_get_str(ctx, host, community, ".1.3.6.1.4.1.14525.4.2.1.4")
    if serial == None or version == None:
        return {
            "changed": False,
            "msg": "juniper trapz chassis present but serial/version unreadable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 juniper trapz chassis",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    message = "S/N: %s, FW Version: %s" % (serial, version)
    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }