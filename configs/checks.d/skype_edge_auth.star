def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "powershell", "-Command",
            "Get-WmiObject -Class \"LS:A/V Auth - Requests\" -Namespace \"root\\cimv2\" | Select-Object -ExpandProperty __SERVER"
        ], mutates=False)
        items = []
        if res.rc == 0 and res.stdout.strip():
            for line in res.stdout.splitlines():
                stripped = line.strip()
                if stripped:
                    items.append({
                        "item": stripped,
                        "params": {"bad_requests": {"upper": (20.0, 40.0)}},
                        "metrics": ["avauth_failed_requests"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run([
        "powershell", "-Command",
        "Get-WmiObject -Class \"LS:A/V Auth - Requests\" -Namespace \"root\\cimv2\" | Select-Object -ExpandProperty \"Bad Requests Received/sec\""
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "WMI query failed or no data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_bad_requests = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.isdigit():
            total_bad_requests = total_bad_requests + int(stripped)

    bad_requests_levels = params.get("bad_requests", {"upper": (20.0, 40.0)})
    warn = float(bad_requests_levels.get("upper", (20.0, 40.0))[0])
    crit = float(bad_requests_levels.get("upper", (20.0, 40.0))[1])

    if total_bad_requests >= crit:
        state = "CRIT"
    elif total_bad_requests >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Bad requests/sec: %d" % total_bad_requests,
        "data": {
            "state": state,
            "metrics": {"avauth_failed_requests": total_bad_requests},
            "details": "",
        },
    }