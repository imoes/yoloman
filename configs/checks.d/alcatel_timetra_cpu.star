def main(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: this plugin monitors an Alcatel-Lucent TiMOS device via SNMP.
    # Detect via sysDescr (.1.3.6.1.2.1.1.1.0) containing "TiMOS".
    sysdesc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdesc.rc != 0 or sysdesc.skipped:
        # Not installed, unreachable, or not a TiMOS device -> absence is an answer
        if params.get("_discover"):
            return {"changed": False, "msg": "no SNMP/TiMOS device present", "data": {"discovery": []}}
        return {"changed": False, "msg": "SNMP probe failed (no TiMOS device)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if "TiMOS" not in sysdesc.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "no TiMOS device present", "data": {"discovery": []}}
        return {"changed": False, "msg": "host is not a TiMOS device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # FETCH: scalar CPU utilization from .1.3.6.1.4.1.6527.3.1.2.1.1.1
    cpu_oid = ".1.3.6.1.4.1.6527.3.1.2.1.1.1"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, cpu_oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        if params.get("_discover"):
            return {"changed": False, "msg": "could not read CPU OID", "data": {"discovery": []}}
        return {"changed": False, "msg": "could not read CPU utilization", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    if not raw:
        if params.get("_discover"):
            return {"changed": False, "msg": "empty CPU value", "data": {"discovery": []}}
        return {"changed": False, "msg": "empty CPU utilization value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_util = float(raw)

    if params.get("_discover"):
        # Single-service check: one item with default cpu_utilization params
        levels = params.get("util", (90.0, 95.0))
        warn = levels[0] if hasattr(levels, "__getitem__") and len(levels) > 0 else 90.0
        crit = levels[1] if hasattr(levels, "__getitem__") and len(levels) > 1 else 95.0
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"util": (warn, crit)}, "metrics": ["cpu_util"]}
            ]},
        }

    # CHECK MODE: apply cpu_utilization thresholds (warn, crit)
    levels = params.get("util", (90.0, 95.0))
    if hasattr(levels, "__getitem__") and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = 90.0
        crit = 95.0

    if cpu_util >= crit:
        state = "CRIT"
    elif cpu_util >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "CPU utilization: %f%%" % cpu_util,
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu_util},
            "details": "",
        },
    }