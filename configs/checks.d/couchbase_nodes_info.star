def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: run the agent probe and discover all node names
        res = ctx.run(["curl", "-s", "-u", params.get("username", "admin") + ":" + params.get("password", ""),
                       "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) +
                       "/pools/default/nodes"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch nodes info",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "empty response from agent",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if data == None or type(data) != "dict":
            return {"changed": False, "msg": "invalid JSON response from agent",
                    "data": {"discovery": []}}
        nodes = data.get("nodes")
        if nodes == None or type(nodes) != "list":
            return {"changed": False, "msg": "invalid nodes list",
                    "data": {"discovery": []}}
        items = []
        for node in nodes:
            if node == None:
                continue
            name = node.get("nodeName")
            if name == None:
                continue
            # Extract simple name without domain if present (e.g., "node-1.example.com" -> "node-1")
            name_simple = name.split(".")[0] if name.find(".") >= 0 else name
            items.append({"item": name_simple, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d nodes" % len(items),
                "data": {"discovery": items}}

    # Check mode: examine one node
    item = params.get("item", "")
    res = ctx.run(["curl", "-s", "-u", params.get("username", "admin") + ":" + params.get("password", ""),
                   "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) +
                   "/pools/default/nodes"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch nodes info",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "empty response from agent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if data == None or type(data) != "dict":
        return {"changed": False, "msg": "invalid JSON response from agent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    nodes = data.get("nodes")
    if nodes == None or type(nodes) != "list":
        return {"changed": False, "msg": "invalid nodes list",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    node_data = None
    for node in nodes:
        if node == None:
            continue
        name = node.get("nodeName")
        if name == None:
            continue
        name_simple = name.split(".")[0] if name.find(".") >= 0 else name
        if name_simple == item:
            node_data = node
            break
    if node_data == None:
        return {"changed": False, "msg": "node not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract fields per the Checkmk check logic
    health = node_data.get("status")
    otpNode = node_data.get("otpNode", "unknown")
    recoveryType = node_data.get("recoveryType", "unknown")
    version = node_data.get("version", "unknown")
    clusterCompatibility = node_data.get("clusterCompatibility", "unknown")
    membership = node_data.get("clusterMembership")

    # Determine health status
    status = "OK"
    if health == "warmup":
        status = "OK" if params.get("warmup_state", 0) == 0 else ("WARN" if params.get("warmup_state", 0) == 1 else "CRIT")
    elif health == "unhealthy":
        status = "OK" if params.get("unhealthy_state", 2) == 0 else ("WARN" if params.get("unhealthy_state", 2) == 1 else "CRIT")
    elif health != None:
        status = "OK"

    # Determine membership status
    mem_status = status
    if membership == "inactiveAdded":
        mem_status = "WARN" if params.get("inactive_added_state", 1) == 1 else ("CRIT" if params.get("inactive_added_state", 1) == 2 else status)
    elif membership == "inactiveFailed":
        mem_status = "CRIT" if params.get("inactive_added_state", 2) == 2 else ("WARN" if params.get("inactive_added_state", 2) == 1 else status)

    # Pick the worst status
    final_status = "OK"
    for s in [status, mem_status]:
        if s == "CRIT":
            final_status = "CRIT"
            break
        elif s == "WARN" and final_status != "CRIT":
            final_status = "WARN"

    # Build summary message
    msg_parts = []
    if health != None:
        msg_parts.append("Health: %s" % health)
    msg_parts.append("otpNode: %s" % otpNode)
    msg_parts.append("recoveryType: %s" % recoveryType)
    msg_parts.append("version: %s" % version)
    msg_parts.append("clusterCompatibility: %s" % clusterCompatibility)
    if membership != None:
        msg_parts.append("clusterMembership: %s" % membership)
    msg = ", ".join(msg_parts)

    return {"changed": False, "msg": msg,
            "data": {"state": final_status, "metrics": {}, "details": ""}}
