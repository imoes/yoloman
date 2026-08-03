def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.3224.21.2.1.2",
            ],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no juniper fans found", "data": {"discovery": []}}
        items = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            index = f[0].split(".")[-1]
            items.append({"item": index, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d fans" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    oid = ".1.3.6.1.4.1.3224.21.2.1.3." + item
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "fan %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = res.stdout.strip()
    if status == "1":
        state = "OK"
        summary = "status is good"
    elif status == "2":
        state = "CRIT"
        summary = "status is failed"
    else:
        state = "CRIT"
        summary = "Unknown fan status %s" % status
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}