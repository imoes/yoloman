def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid = ".1.3.6.1.2.1.1.2.0"
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if sys_res.rc != 0 or sys_res.skipped:
        return {
            "changed": False,
            "msg": "SNMP not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sys_oid_val = sys_res.stdout.strip().strip('"')

    if not sys_oid_val.startswith(".1.3.6.1.4.1.12356.105"):
        return {
            "changed": False,
            "msg": "not a FortiMail device",
            "data": {"discovery": []},
        } if params.get("_discover") else {
            "changed": False,
            "msg": "not a FortiMail device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base_oid = ".1.3.6.1.4.1.12356.105.1.30"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "not a FortiMail device",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "FortiMail CPU load OID not accessible",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if raw == "" or raw == "No SuchInstance" or raw == "No Such Object":
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "not a FortiMail device",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "FortiMail CPU load OID not accessible",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    val = raw
    if val.startswith("STRING: "):
        val = val[len("STRING: "):]
    elif val.startswith("INTEGER: "):
        val = val[len("INTEGER: "):]
    elif ": " in val:
        idx = val.find(": ")
        val = val[idx + 2:]
    val = val.strip().strip('"')

    if not val:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "not a FortiMail device",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "FortiMail CPU load OID not accessible",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    cpu_load = float(val)

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"cpu_load": None},
                        "metrics": ["load_instant"],
                    }
                ]
            },
        }

    levels = params.get("cpu_load")
    warn = None
    crit = None
    if levels != None and type(levels) == "list":
        if len(levels) >= 1:
            warn = levels[0]
        if len(levels) >= 2:
            crit = levels[1]

    state = "OK"
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        if cpu_load >= crit:
            state = "CRIT"
        elif cpu_load >= warn:
            state = "WARN"

    msg = "CPU load %s" % str(cpu_load)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"load_instant": cpu_load},
            "details": "",
        },
    }