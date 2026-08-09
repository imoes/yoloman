def main(ctx, params):
    if params.get("_discover"):
        # AppDynamics data comes from the controller REST API, not from any
        # on-host source in Checkmk's agent. The controller host is configured
        # via the "host" and "community"-style params passed by the operator.
        host = params.get("host", "localhost")
        port = params.get("port", 8080)
        user = params.get("user")
        password = params.get("password")
        app = params.get("app")
        tier = params.get("tier")

        if not user or not password or not app or not tier:
            return {
                "changed": False,
                "msg": "AppDynamics controller params not configured; nothing to discover",
                "data": {"discovery": []},
            }

        url = "http://%s:%s/controller/api/v1/applications/%s/tiers/%s/nodes" % (host, port, app, tier)
        res = ctx.run(
            ["curl", "-s", "-u", "%s:%s" % (user, password), "-X", "GET", url],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "could not reach AppDynamics controller at %s" % host,
                "data": {"discovery": []},
            }

        nodes = json.decode(res.stdout)
        out = []
        for node in nodes:
            name = node.get("nodeName")
            if name == None:
                continue
            out.append({
                "item": name,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["current_threads", "busy_threads", "error_rate", "request_rate"],
            })
        return {
            "changed": False,
            "msg": "discovered %d AppDynamics nodes" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", 8080)
    user = params.get("user")
    password = params.get("password")
    app = params.get("app")
    tier = params.get("tier")

    if not user or not password or not app or not tier:
        return {
            "changed": False,
            "msg": "AppDynamics controller params not configured",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    url = "http://%s:%s/controller/api/v1/applications/%s/tiers/%s/nodes/%s/metrics" % (host, port, app, tier, item)
    res = ctx.run(
        ["curl", "-s", "-u", "%s:%s" % (user, password), "-X", "GET", url],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no AppDynamics node named %s found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = json.decode(res.stdout)
    metrics = {}
    for entry in data:
        path = entry.get("metricPath", "")
        values = entry.get("metricValues", [])
        if len(values) == 0:
            continue
        value = values[0].get("value", 0)
        if path == "Server Threads|Thread Pools|Current Threads In Pool":
            metrics["current_threads"] = value
        elif path == "Server Threads|Thread Pools|Busy Threads":
            metrics["busy_threads"] = value
        elif path == "Server Threads|Thread Pools|Maximum Threads":
            metrics["max_threads"] = value
        elif path == "Errors|Error Count":
            metrics["error_count"] = value
        elif path == "Requests|Request Count":
            metrics["request_count"] = value

    current_threads = metrics.get("current_threads")
    busy_threads = metrics.get("busy_threads")
    max_threads = metrics.get("max_threads")

    state = "OK"
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    if current_threads != None and max_threads != None and max_threads > 0:
        pct = 100.0 * current_threads / max_threads
        if pct >= crit:
            state = "CRIT"
        elif pct >= warn:
            state = "WARN"

    summary = "Current threads: %s, Busy threads: %s" % (current_threads, busy_threads)
    if current_threads != None and max_threads != None:
        pct = 100.0 * current_threads / max(1, max_threads)
        summary = summary + " (%d%% of %d)" % (pct, max_threads)

    return {
        "changed": False,
        "msg": "AppDynamics Web Container %s: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": {
                "current_threads": current_threads,
                "busy_threads": busy_threads,
            },
            "details": "",
        },
    }