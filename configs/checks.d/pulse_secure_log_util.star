def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12532.1"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "pulse secure not present", "data": {"discovery": []}}

        if not res.stdout.strip().isdigit():
            return {"changed": False, "msg": "pulse secure not present", "data": {"discovery": []}}

        val = int(res.stdout.strip())

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": (80, 90)},
                        "metrics": ["log_file_utilization"],
                    }
                ]
            },
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12532.1"],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no pulse secure log util data: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sval = res.stdout.strip()
    if not sval.isdigit():
        return {
            "changed": False,
            "msg": "invalid pulse secure log util value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pct = int(sval)

    levels = params.get("levels", (80, 90))
    if len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)

    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Pulse Secure log file utilization at %d%%" % pct,
        "data": {
            "state": state,
            "metrics": {"log_file_utilization": pct},
            "details": "Percentage of log file used: %d%%" % pct,
        },
    }