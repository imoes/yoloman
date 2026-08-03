def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")  # not used for HTTP
    username = params.get("username", "Administrator")
    password = params.get("password", "")
    port = params.get("port", "8091")
    
    # Probe: check if Couchbase is running by accessing the REST API
    url = "http://%s:%s/pools/default" % (host, port)
    res = ctx.run(["curl", "-s", "-u", "%s:%s" % (username, password), url], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        if res.rc == 127:
            return {"changed": False, "msg": "curl not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # Try without auth (Couchbase may allow it for basic info)
        res = ctx.run(["curl", "-s", url], mutates=False)
        if res.rc != 0 or not res.stdout:
            if params.get("_discover"):
                return {"changed": False, "msg": "Couchbase not reachable",
                        "data": {"discovery": []}}
            return {"changed": False, "msg": "Couchbase not reachable",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    nodes = data.get("nodes", [])
    
    if params.get("_discover"):
        out = []
        for node in nodes:
            node_name = node.get("hostname", "")
            if not node_name:
                node_name = node.get("name", "")
            if node_name:
                out.append({"item": node_name, "params": {},
                            "metrics": ["size_on_disk", "data_size"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    
    # Find the node matching the item
    node_data = None
    for node in nodes:
        node_name = node.get("hostname", "")
        if not node_name:
            node_name = node.get("name", "")
        if node_name == item:
            node_data = node
            break
    
    if node_data == None:
        return {"changed": False, "msg": "node %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract spatial views metrics
    on_disk = node_data.get("couch_spatial_disk_size")
    size = node_data.get("couch_spatial_data_size")
    
    metrics = {}
    states = []
    details_parts = []
    
    warn_on_disk = params.get("size_on_disk", {}).get("warn") if type(params.get("size_on_disk")) == "dict" else None
    crit_on_disk = params.get("size_on_disk", {}).get("crit") if type(params.get("size_on_disk")) == "dict" else None
    
    warn_size = params.get("size", {}).get("warn") if type(params.get("size")) == "dict" else None
    crit_size = params.get("size", {}).get("crit") if type(params.get("size")) == "dict" else None
    
    if on_disk != None:
        metrics["size_on_disk"] = on_disk
        states.append(_grade_upper(on_disk, warn_on_disk, crit_on_disk))
        details_parts.append("Size on disk: %s" % _render_bytes(on_disk))
    
    if size != None:
        metrics["data_size"] = size
        states.append(_grade_upper(size, warn_size, crit_size))
        details_parts.append("Data size: %s" % _render_bytes(size))
    
    # Determine worst state
    state = "OK"
    for s in states:
        if s == "CRIT":
            state = "CRIT"
        elif s == "WARN" and state != "CRIT":
            state = "WARN"
    
    msg = "%s Spacial Views: %s" % (item, ", ".join(details_parts)) if details_parts else "%s Spacial Views" % item
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}

def _grade_upper(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _render_bytes(n):
    if n >= 1073741824:
        return "%f GB" % (float(n) / 1073741824)
    if n >= 1048576:
        return "%f MB" % (float(n) / 1048576)
    if n >= 1024:
        return "%f KB" % (float(n) / 1024)
    return "%d B" % n