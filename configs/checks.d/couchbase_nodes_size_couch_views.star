# Top-level constants (no imports, no classes, no lambdas)
METRICS_COUCH_VIEWS = {
    "on_disk": "couch_views_actual_disk_size",
    "size": "couch_views_data_size",
}

def main(ctx, params):
    if params.get("_discover"):
        # Run the agent probe: fetch all nodes data from the JSON file
        res = ctx.run(["cat", "/var/lib/check-mk-agent/couchbase-nodes-size.json"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no data available", "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no data available", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {"changed": False, "msg": "unexpected data format", "data": {"discovery": []}}

        items = []
        for item_name in data.keys():
            items.append({
                "item": item_name,
                "params": {},
                "metrics": ["size_on_disk", "data_size"],
            })
        return {"changed": False, "msg": "discovered %d nodes" % len(items), "data": {"discovery": items}}

    # Check mode (single item)
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/couchbase-nodes-size.json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if type(data) != "dict" or data.get(item) == None:
        return {"changed": False, "msg": "node not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    node_data = data.get(item)
    on_disk = node_data.get(METRICS_COUCH_VIEWS["on_disk"])
    size = node_data.get(METRICS_COUCH_VIEWS["size"])

    # Determine state and metrics (only warn/crit levels, upper bounds)
    state = "OK"
    metrics = {}
    details_parts = []

    if on_disk != None:
        metrics["size_on_disk"] = int(on_disk)
        warn_on_disk = params.get("size_on_disk")
        crit_on_disk = params.get("size_on_disk")
        # Checkmk's default: levels_upper(("fixed", (levels_tuple))) — but check_default_parameters is {}
        # So use no levels if params missing -> only report value, no state change
        if warn_on_disk != None and crit_on_disk != None:
            warn_val = int(warn_on_disk) if type(warn_on_disk) == "int" else 0
            crit_val = int(crit_on_disk) if type(crit_on_disk) == "int" else 0
            if on_disk >= crit_val:
                state = "CRIT"
            elif on_disk >= warn_val:
                state = "WARN"
        details_parts.append("Size on disk: " + str(int(on_disk)))

    if size != None:
        metrics["data_size"] = int(size)
        warn_size = params.get("size")
        crit_size = params.get("size")
        if warn_size != None and crit_size != None:
            warn_val = int(warn_size) if type(warn_size) == "int" else 0
            crit_val = int(crit_size) if type(crit_size) == "int" else 0
            if size >= crit_val:
                state = "CRIT"
            elif size >= warn_val:
                state = "WARN"
        details_parts.append("Data size: " + str(int(size)))

    details = ", ".join(details_parts) if details_parts else ""
    return {"changed": False, "msg": "%s: %s" % (item, details), "data": {"state": state, "metrics": metrics, "details": details}}
