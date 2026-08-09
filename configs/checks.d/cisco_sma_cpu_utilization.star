def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = ".1.3.6.1.4.1.15497.1.1.1.2"

    # Probe for the real thing: SNMPv2-MIB::snmpUseNumericAddresses check is
    # not available; instead detect the Cisco SMA device via the enterprise OID.
    detect = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.15497.1.1.1"],
        mutates=False,
    )
    if detect.rc == 127:
        return {"changed": False, "msg": "discovery: not installed",
                "data": {"discovery": []}}
    if detect.rc != 0:
        return {"changed": False, "msg": "discovery: device not present",
                "data": {"discovery": []}}

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered CPU utilization",
                "data": {"discovery": [
                    {"item": "", "params": {"util": (70.0, 80.0)}, "metrics": ["cpu_utilization"]}
                ]}}

    item = params.get("item", "")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "no snmpget installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "could not read CPU utilization",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = float(res.stdout.strip())
    levels = params.get("util", (70.0, 80.0))
    warn = levels[0]
    crit = levels[1]
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")
    return {"changed": False, "msg": "CPU utilization: %f%%" % util,
            "data": {"state": state, "metrics": {"cpu_utilization": util}, "details": ""}}