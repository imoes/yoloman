def main(ctx, params):
    # Discovery mode: enumerate nodes with curr_items data
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/couchbase/agent/nodes_items.json"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 nodes (no data available)",
                    "data": {"discovery": []}}

        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 nodes (no data available)",
                    "data": {"discovery": []}}

        data = json.decode(res.stdout)

        items = []
        for node_name, node_data in data.items():
            if isinstance(node_data, dict) and "curr_items" in node_data:
                items.append({
                    "item": node_name,
                    "params": {},
                    "metrics": ["items_active", "items_non_res", "items"]
                })
        return {"changed": False, "msg": "discovered %d nodes" % len(items),
                "data": {"discovery": items}}

    # Check mode: examine one node item
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/couchbase/agent/nodes_items.json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)

    if item not in data:
        return {"changed": False, "msg": "node not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    node_data = data[item]
    if not isinstance(node_data, dict):
        return {"changed": False, "msg": "invalid node data format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract values
    active = node_data.get("curr_items")
    non_res = node_data.get("vb_active_num_non_resident")
    total = node_data.get("curr_items_tot")

    # Determine state and build message
    state = "OK"
    msg_parts = []

    # Process curr_items (active)
    if active != None:
        warn = params.get("curr_items")
        crit = None
        # Checkmk uses only upper levels, so we interpret tuple as (warn, crit)
        if isinstance(warn, list) and len(warn) == 2:
            warn = warn[0]
            crit = warn[1]
        if isinstance(warn, int) and active >= warn:
            state = "WARN"
        if isinstance(crit, int) and active >= crit:
            state = "CRIT"
        msg_parts.append("Items in active vBuckets: %s" % str(active))

    # Process vb_active_num_non_resident (non_residents)
    if non_res != None:
        warn = params.get("non_residents")
        crit = None
        if isinstance(warn, list) and len(warn) == 2:
            warn = warn[0]
            crit = warn[1]
        if isinstance(warn, int) and non_res >= warn:
            state = "WARN"
        if isinstance(crit, int) and non_res >= crit:
            state = "CRIT"
        msg_parts.append("Non-resident items: %s" % str(non_res))

    # Process curr_items_tot (total)
    if total != None:
        warn = params.get("curr_items_tot")
        crit = None
        if isinstance(warn, list) and len(warn) == 2:
            warn = warn[0]
            crit = warn[1]
        if isinstance(warn, int) and total >= warn:
            state = "WARN"
        if isinstance(crit, int) and total >= crit:
            state = "CRIT"
        msg_parts.append("Total items in vBuckets: %s" % str(total))

    metrics = {}
    if active != None:
        metrics["items_active"] = int(active)
    if non_res != None:
        metrics["items_non_res"] = int(non_res)
    if total != None:
        metrics["items"] = int(total)

    return {"changed": False,
            "msg": ", ".join(msg_parts) if msg_parts else "no metrics available",
            "data": {"state": state, "metrics": metrics, "details": ""}}