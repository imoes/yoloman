def main(ctx, params):
    # Discovery mode: enumerate all nginx server instances
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "http://127.0.0.1:80/nginx_status"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 instances", "data": {"discovery": []}}
        
        # Parse simple format: each instance has exactly 4 lines
        lines = res.stdout.splitlines()
        instances = []
        i = 0
        while i < len(lines):
            # Expected format: "address port ..."
            parts = lines[i].split()
            if len(parts) >= 2:
                address = parts[0]
                port = parts[1]
                item = "%s:%s" % (address, port)
                instances.append({"item": item, "params": {}, "metrics": ["active", "reading", "writing", "waiting", "requests", "accepted", "handled"]})
            # Skip 4 lines per block
            i += 4
        return {"changed": False, "msg": "discovered %d instances" % len(instances),
                "data": {"discovery": instances}}

    # Check mode: examine single item
    item = params.get("item", "")
    res = ctx.run(["curl", "-s", "http://127.0.0.1:80/nginx_status"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "curl command failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    # Parse section data into dict
    data = {}
    i = 0
    while i < len(lines):
        parts = lines[i].split()
        if len(parts) >= 2:
            address = parts[0]
            port = parts[1]
            key = "%s:%s" % (address, port)
            if i + 3 < len(lines):
                # Line 0: "address port Active connections: N"
                active_parts = lines[i].split()
                active = int(active_parts[4]) if (len(active_parts) > 4 and active_parts[4].isdigit()) else 0
                
                # Line 2: "address port  A H R" (accepts handled requests)
                line2_parts = lines[i+2].split()
                accepted = int(line2_parts[2]) if (len(line2_parts) > 2 and line2_parts[2].isdigit()) else 0
                handled = int(line2_parts[3]) if (len(line2_parts) > 3 and line2_parts[3].isdigit()) else 0
                requests = int(line2_parts[4]) if (len(line2_parts) > 4 and line2_parts[4].isdigit()) else 0
                
                # Line 3: "address port Reading: R Writing: W Waiting: X"
                line3_parts = lines[i+3].split()
                reading = int(line3_parts[3]) if (len(line3_parts) > 3 and line3_parts[3].isdigit()) else 0
                writing = int(line3_parts[5]) if (len(line3_parts) > 5 and line3_parts[5].isdigit()) else 0
                waiting = int(line3_parts[7]) if (len(line3_parts) > 7 and line3_parts[7].isdigit()) else 0
                
                data[key] = {
                    "active": active,
                    "accepted": accepted,
                    "handled": handled,
                    "requests": requests,
                    "reading": reading,
                    "writing": writing,
                    "waiting": waiting
                }
        i += 4
    
    if item not in data:
        return {"changed": False, "msg": "instance not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract data
    d = data[item]
    
    # Calculate derived values
    requests_per_conn = 1.0 * d["requests"] / d["handled"] if d["handled"] > 0 else 0.0
    
    # Get levels
    active_levels = params.get("active_connections")
    warn_active = active_levels[0] if active_levels and len(active_levels) >= 1 else None
    crit_active = active_levels[1] if active_levels and len(active_levels) >= 2 else None
    
    # State calculation for active connections
    state = "OK"
    if crit_active != None and d["active"] >= crit_active:
        state = "CRIT"
    elif warn_active != None and d["active"] >= warn_active:
        state = "WARN"
    
    # Prepare metrics
    metrics = {
        "reading": d["reading"],
        "writing": d["writing"],
        "waiting": d["waiting"],
        "active": d["active"],
        "requests": d["requests"],
        "accepted": d["accepted"],
        "handled": d["handled"]
    }
    
    # Build message
    msg = "Active: %d (%d reading, %d writing, %d waiting)" % (
        d["active"], d["reading"], d["writing"], d["waiting"]
    )
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}