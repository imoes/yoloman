def main(ctx, params):
    # Read the couchbase_nodes_operations agent section
    # Fetch node stats from the Couchbase REST API
    host = params.get("host", "localhost")
    port = params.get("port", "8091")
    user = params.get("user", "admin")
    password = params.get("password", "password")
    protocol = params.get("protocol", "http")
    base_url = "%s://%s:%s" % (protocol, host, port)
    
    res = ctx.run([
        "curl", "-s", "-u", "%s:%s" % (user, password),
        "%s/pools/default/nodeStats" % base_url
    ], mutates=False)
    
    # Handle curl failure
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to fetch node stats from Couchbase: %s" % res.stderr.strip(),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Parse JSON — guard against empty or malformed output
    if res.stdout == "":
        return {
            "changed": False,
            "msg": "Empty response from node stats endpoint",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    data = json.decode(res.stdout) if res.stdout != "" else {}
    
    if type(data) != "dict" or not data.get("nodes"):
        return {
            "changed": False,
            "msg": "Unexpected node stats format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    nodes = data.get("nodes")
    if type(nodes) != "list" or len(nodes) == 0:
        return {
            "changed": False,
            "msg": "No node data found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Parse the section into a dict {node_name: ops} and total (None)
    section = {}
    total_ops = 0.0
    
    for node_entry in nodes:
        node_name = node_entry.get("hostname", "")
        if node_name == "":
            continue
        ops_raw = node_entry.get("ops", 0.0)
        # Ensure ops is a number
        ops = ops_raw
        if type(ops) == "string":
            # Check for integer-like or float-like strings
            ops_clean = ops.strip()
            is_int_like = ops_clean.isdigit() or (ops_clean.startswith("-") and ops_clean[1:].isdigit())
            if is_int_like:
                ops = int(ops_clean)
            elif ops_clean.replace(".", "", 1).isdigit() or (ops_clean.startswith("-") and ops_clean[1:].replace(".", "", 1).isdigit()):
                ops = float(ops_clean)
            else:
                ops = 0.0
        elif type(ops) != "int" and type(ops) != "float":
            ops = 0.0
        
        section[node_name] = float(ops)
        total_ops += float(ops)
    
    section[None] = total_ops
    
    # Discovery mode
    if params.get("_discover"):
        discovered = []
        for node_name in section:
            if node_name != None:
                discovered.append({
                    "item": node_name,
                    "params": {},
                    "metrics": ["op_s"],
                })
        return {
            "changed": False,
            "msg": "discovered %d nodes" % len(discovered),
            "data": {"discovery": discovered},
        }
    
    # Check mode: process the given item
    item = params.get("item", "")
    value = section.get(item)
    
    if value == None:
        return {
            "changed": False,
            "msg": "Node not found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Extract levels from params
    ops_levels = params.get("ops")
    
    # Determine state: WARN if >= warn, CRIT if >= crit
    state = "OK"
    
    if ops_levels != None:
        warn_val, crit_val = ops_levels
        if float(value) >= float(crit_val):
            state = "CRIT"
        elif float(value) >= float(warn_val):
            state = "WARN"
    
    # Format the value
    value_str = "%f/s" % float(value)
    details = ""
    
    if state == "CRIT":
        details = " (critical)"
    elif state == "WARN":
        details = " (warning)"
    
    msg = "%s: %s" % (item, value_str) + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"op_s": float(value)},
            "details": "",
        },
    }