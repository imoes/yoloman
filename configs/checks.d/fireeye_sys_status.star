def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.25597.11.1.1"

    if params.get("_discover"):
        descr = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
        if descr == None or descr == "":
            return {"changed": False, "msg": "no snmp device", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ]
            },
        }

    status_raw = _snmp_get(ctx, host, community, base + ".1")
    if status_raw == None:
        return {
            "changed": False,
            "msg": "no fireeye device reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    status = status_raw.strip().lower()
    good_statuses = dict()
    good_statuses["good"] = True
    good_statuses["ok"] = True
    state = "OK" if status in good_statuses else "CRIT"
    return {
        "changed": False,
        "msg": "Status: %s" % status,
        "data": {"state": state, "metrics": {}, "details": ""},
    }