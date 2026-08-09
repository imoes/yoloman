def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real Couchbase product on the host.
        res = ctx.run(["couchbase-cli", "node-list", "--help"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "couchbase-cli not found",
                    "data": {"discovery": []}}

        # Read the actual node/uptime data from the local Couchbase nodes.
        # We reproduce the Checkmk agent section by querying Couchbase's
        # REST API (the same source the lib/uptime Checkmk plugin reads).
        # In absence of a real on-host source, report absence honestly.
        api = ctx.run(
            ["curl", "-s", "--max-time", "5",
             "http://localhost:8091/pools/default"],
            mutates=False,
        )
        if api.rc != 0 or not api.stdout:
            return {"changed": False, "msg": "couchbase rest api not reachable",
                    "data": {"discovery": []}}

        data = json.decode(api.stdout)
        nodes = data.get("nodes", []) if type(data) == "dict" else []
        out = []
        for node in nodes:
            if type(node) != "dict":
                continue
            hostname = node.get("hostname", "")
            if not hostname:
                continue
            uptime_val = node.get("uptime", None)
            if uptime_val == None:
                continue
            out.append({
                "item": hostname,
                "params": {},
                "metrics": ["uptime"],
            })
        return {"changed": False,
                "msg": "discovered %d couchbase nodes" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Re-probe the real host source (Couchbase REST API on localhost).
    api = ctx.run(
        ["curl", "-s", "--max-time", "5",
         "http://localhost:8091/pools/default"],
        mutates=False,
    )
    if api.rc != 0 or not api.stdout:
        return {"changed": False,
                "msg": "no couchbase instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(api.stdout)
    nodes = data.get("nodes", []) if type(data) == "dict" else []

    found = None
    for node in nodes:
        if type(node) != "dict":
            continue
        if node.get("hostname", "") == item:
            found = node
            break

    if found == None:
        return {"changed": False,
                "msg": "no couchbase node found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    uptime_val = found.get("uptime", None)
    if uptime_val == None or not uptime_val.isdigit():
        return {"changed": False,
                "msg": "no uptime data for node: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    uptime_seconds = int(uptime_val)
    warn = params.get("warn", None)
    crit = params.get("crit", None)

    state = "OK"
    if warn != None and crit != None:
        if uptime_seconds <= crit:
            state = "CRIT"
        elif uptime_seconds <= warn:
            state = "WARN"

    days = uptime_seconds // 86400
    hours = (uptime_seconds % 86400) // 3600
    minutes = (uptime_seconds % 3600) // 60
    pretty = "%dd %dh %dm" % (days, hours, minutes)

    return {"changed": False,
            "msg": "Uptime: %s" % pretty,
            "data": {"state": state,
                     "metrics": {"uptime": uptime_seconds},
                     "details": pretty}}