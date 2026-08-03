def main(ctx, params):
    if params.get("_discover"):
        cb = ctx.run(["couchbase-cli", "server-list", "-c", "localhost"], mutates=False)
        if cb.rc == 127 or not cb.stdout:
            return {"changed": False, "msg": "couchbase not found on host", "data": {"discovery": []}}
        discovery = []
        for line in cb.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            node = f[0]
            services = f[1:]
            discovery.append({"item": node, "params": {"discovered_services": services},
                              "metrics": []})
        return {"changed": False,
                "msg": "discovered %d couchbase nodes" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    cb = ctx.run(["couchbase-cli", "server-list", "-c", "localhost"], mutates=False)
    if cb.rc == 127 or not cb.stdout:
        return {"changed": False,
                "msg": "no couchbase node found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    services_present = []
    found = False
    for line in cb.stdout.splitlines():
        f = line.split()
        if len(f) < 2 or f[0] != item:
            continue
        found = True
        services_present = f[1:]
        break

    if not found:
        return {"changed": False,
                "msg": "no such couchbase node: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    services_discovered = params.get("discovered_services", [])
    present = set(services_present)
    discovered = set(services_discovered)
    vanished = sorted(discovered - present)
    appeared = sorted(present - discovered)
    unchanged = sorted(discovered & present)

    msgs = []
    if vanished:
        msgs.append("CRIT %d services vanished: %s" % (len(vanished), ", ".join(vanished)))
    if appeared:
        msgs.append("CRIT %d services appeared: %s" % (len(appeared), ", ".join(appeared)))

    worst = "OK"
    if appeared or vanished:
        worst = "CRIT"

    summary = "%d services unchanged: %s" % (len(unchanged), ", ".join(unchanged))
    if msgs:
        detail = "; ".join(msgs) + "; " + summary
    else:
        detail = summary

    return {"changed": False,
            "msg": detail,
            "data": {"state": worst,
                     "metrics": {},
                     "details": detail}}