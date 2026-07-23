def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        port = params.get("port", 8091)
        user = params.get("user", "admin")
        password = params.get("password", "")
        # Build basic auth header manually via curl's -u; Starlark has no base64, but curl handles it
        args = ["curl", "-s", "-S", "-u", user + ":" + password if user and password else "",
                "-k", "https://" + host + ":" + str(port) + "/pools/nodes"]
        res = ctx.run(args, mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no data from couchbase",
                    "data": {"discovery": []}}
        # Guard: only decode if output looks like JSON
        if len(res.stdout) == 0 or res.stdout[0] != '{':
            return {"changed": False, "msg": "invalid JSON from couchbase",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        items = []
        for node in data.get("nodes", []):
            node_name = node.get("hostname", node.get("nodeUUID", "")).split(":")[0]
            services = node.get("services", [])
            items.append({
                "item": node_name,
                "params": {"discovered_services": services},
                "metrics": []
            })
        return {"changed": False, "msg": "discovered %d nodes" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("user", "admin")
    password = params.get("password", "")
    args = ["curl", "-s", "-S", "-u", user + ":" + password if user and password else "",
            "-k", "https://" + host + ":" + str(port) + "/pools/nodes"]
    res = ctx.run(args, mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data from couchbase",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Guard before decode
    if len(res.stdout) == 0 or res.stdout[0] != '{':
        return {"changed": False, "msg": "invalid JSON from couchbase",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    node_data = None
    for node in data.get("nodes", []):
        node_name = node.get("hostname", node.get("nodeUUID", "")).split(":")[0]
        if node_name == item:
            node_data = node
            break
    if node_data == None:
        return {"changed": False, "msg": "node not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    services_present = set(node_data.get("services", []))
    services_discovered = set(params.get("discovered_services", []))
    services_appeared = services_present - services_discovered
    services_vanished = services_discovered - services_present
    services_unchanged = services_discovered & services_present
    summary_parts = []
    if services_vanished:
        srt = sorted(services_vanished)
        summary_parts.append("%d services vanished: %s" % (len(srt), ", ".join(srt)))
    if services_appeared:
        srt = sorted(services_appeared)
        summary_parts.append("%d services appeared: %s" % (len(srt), ", ".join(srt)))
    srt = sorted(services_unchanged)
    summary_parts.append("%d services unchanged: %s" % (len(srt), ", ".join(srt)))
    summary = "; ".join(summary_parts)
    if services_vanished or services_appeared:
        state = "CRIT"
    else:
        state = "OK"
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
