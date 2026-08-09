# hp_procurve_cpu: CPU utilization check for HP ProCurve switches
# Translated from Checkmk checkmk.hp_procurve_cpu
# Data source: SNMP (OIDs from the Checkmk SNMPTree definition)

# The Checkmk SNMPTree base is ".1.3.6.1.4.1.11.2.14.11.5.1.9.6" with oids=["1"],
# yielding the full OID "1.3.6.1.4.1.11.2.14.11.5.1.9.6.1".
# Detection uses sysObjectID (.1.3.6.1.2.1.1.2.0) matching
# ".11.2.3.7.11" or ".11.2.3.7.8".

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    cpu_oid = "1.3.6.1.4.1.11.2.14.11.5.1.9.6.1"
    sysid_oid = ".1.3.6.1.2.1.1.2.0"

    if params.get("_discover"):
        # Probe for the real thing: verify this is an HP ProCurve device.
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, sysid_oid],
            mutates=False,
        )
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "HP ProCurve CPU not detected",
                    "data": {"discovery": []}}
        sysid_val = res.stdout.strip()
        if sysid_val != ".11.2.3.7.11" and sysid_val != ".11.2.3.7.8":
            return {"changed": False, "msg": "not an HP ProCurve device",
                    "data": {"discovery": []}}
        # Fetch the CPU utilization value to confirm it's available and valid.
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, cpu_oid],
            mutates=False,
        )
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "no CPU utilization available",
                    "data": {"discovery": []}}
        val = res.stdout.strip()
        if not val.lstrip("-").isdigit():
            return {"changed": False, "msg": "invalid CPU utilization value",
                    "data": {"discovery": []}}
        util = int(val)
        if (0 <= util) and (util <= 100):
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "",
                         "params": {"util": (80.0, 90.0)},
                         "metrics": ["cpu_utilization"]}]}}
        return {"changed": False, "msg": "CPU utilization out of range",
                "data": {"discovery": []}}

    # CHECK MODE: check the single item (item "" for this single-service check).
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, cpu_oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "no CPU utilization available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = res.stdout.strip()
    if not val.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid CPU utilization: " + val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util = int(val)
    if not ((0 <= util) and (util <= 100)):
        return {"changed": False, "msg": "CPU utilization out of range: " + val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("util", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")
    return {"changed": False, "msg": "CPU utilization " + str(util) + "%",
            "data": {"state": state, "metrics": {"cpu_utilization": util}, "details": ""}}