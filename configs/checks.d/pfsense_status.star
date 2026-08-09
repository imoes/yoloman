def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run(
            [
                "snmpget", "-v2c", "-c",
                params.get("community", "public"),
                "-Oqv", params.get("host", "localhost"),
                ".1.3.6.1.2.1.1.1.0",
            ],
            mutates=False,
        )
        if detect.rc != 0 or not detect.stdout.lower().find("pfsense"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": [], "host_labels": {}}}
        res = ctx.run(
            [
                "snmpget", "-v2c", "-c",
                params.get("community", "public"),
                "-Oqv", params.get("host", "localhost"),
                ".1.3.6.1.4.1.12325.1.200.1.1.1",
            ],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    res = ctx.run(
        [
            "snmpget", "-v2c", "-c",
            params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            ".1.3.6.1.4.1.12325.1.200.1.1.1",
        ],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "pfSense status not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = res.stdout.strip()
    if value == "1":
        return {"changed": False, "msg": "Running",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if value == "2":
        return {"changed": False, "msg": "Not running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Unknown status value: %s" % value,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}