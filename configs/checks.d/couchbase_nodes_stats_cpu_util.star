def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Fetch node stats from the same endpoint as Checkmk agent: Couchbase REST API
        res = ctx.run([
            "curl", "-s", "-f", "http://localhost:8091/pools/default/nodes"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (couchbase endpoint unreachable)",
                    "data": {"discovery": []}}

        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 items (no data from couchbase)",
                    "data": {"discovery": []}}

        nodes = json.decode(res.stdout)

        items = []
        for node in nodes.get("nodes", []):
            name = ""
            hostname = node.get("hostname", "")
            if hostname:
                name = hostname.split(":")[0]
            if not name:
                name = node.get("nodeID", "")
            if name:
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["cpu_utilization_rate"]
                })

        return {"changed": False, "msg": "discovered %d nodes" % len(items),
                "data": {"discovery": items}}

    # Check mode: item is required
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item not specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch node stats from the same endpoint
    res = ctx.run([
        "curl", "-s", "-f", "http://localhost:8091/pools/default/nodes"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Couchbase endpoint unreachable for node %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False, "msg": "no data from Couchbase for node %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nodes = json.decode(res.stdout)

    data = None
    for node in nodes.get("nodes", []):
        name = ""
        hostname = node.get("hostname", "")
        if hostname:
            name = hostname.split(":")[0]
        if not name:
            name = node.get("nodeID", "")
        if name == item:
            data = node
            break

    if not data:
        return {"changed": False, "msg": "node %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_util_str = data.get("cpuUtilizationRate", data.get("cpu_utilization_rate", ""))
    if cpu_util_str == "":
        return {"changed": False, "msg": "cpu_utilization_rate missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = 0.0
    if cpu_util_str.isdigit() or (cpu_util_str.replace(".", "", 1).isdigit() and cpu_util_str.count(".") <= 1):
        util = float(cpu_util_str)
    else:
        return {"changed": False, "msg": "cpu_utilization_rate invalid: " + cpu_util_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Thresholds: Checkmk's cpu_utilization_multiitem default is (80.0, 90.0)
    warn, crit = 80.0, 90.0
    levels = params.get("levels", None)
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"

    msg = "CPU utilization: %f%%" % util
    if state == "OK":
        msg += " (warn/crit at %f/%f%%)" % (warn, crit)
    elif state == "WARN":
        msg += " (warn/crit at %f/%f%%)" % (warn, crit)
    else:
        msg += " (warn/crit at %f/%f%%)" % (warn, crit)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"cpu_utilization_rate": util}, "details": ""}}
