def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("levels", (30000, 35000))
    warn = levels[0]
    crit = levels[1]

    if params.get("_discover"):
        # DECTECT: only discover on Domino-capable systems
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0 or sysid.rc == 127:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        sysid_val = sysid.stdout.strip()
        is_domino = False
        domino_oids = [
            ".1.3.6.1.4.1.311.1.1.3.1.2",
            ".1.3.6.1.4.1.8072.3.1.10",
            ".1.3.6.1.4.1.8072.3.2.10",
        ]
        for oid in domino_oids:
            if sysid_val.startswith(oid):
                is_domino = True
                break
        if not is_domino:
            return {"changed": False, "msg": "no Domino detected", "data": {"discovery": []}}

        # FETCH the transaction OID
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.334.72.1.1.6.3.2"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no Domino transactions data", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": (warn, crit)},
                        "metrics": ["transactions"],
                    }
                ],
            },
        }

    item = params.get("item", "")

    # CHECK MODE: single-service check (item == "")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.334.72.1.1.6.3.2"],
        mutates=False,
    )
    if res.rc != 0 or res.rc == 127:
        return {
            "changed": False,
            "msg": "Domino SNMP not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if not raw or not raw.lstrip("-").isdigit():
        return {
            "changed": False,
            "msg": "invalid transaction value from Domino",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = int(raw)
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "%d transactions/min" % value,
        "data": {
            "state": state,
            "metrics": {"transactions": value},
            "details": "",
        },
    }