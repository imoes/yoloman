def main(ctx, params):
    if params.get("_discover"):
        # Run postfix mailq command to gather queue data
        res = ctx.run(["postqueue", "-p"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "postqueue command failed", 
                    "data": {"discovery": []}}
        
        # Parse the output to extract queue instances
        lines = res.stdout.splitlines()
        queue_data = {}
        current_queue = "default"
        queue_name = None
        size = 0
        length = 0
        
        for line in lines:
            stripped = line.strip()
            if stripped == "-- Queue is empty --":
                queue_data.setdefault("default", []).append({
                    "name": "empty",
                    "size": 0,
                    "length": 0
                })
                break
            elif stripped.startswith("Mail queue is empty"):
                queue_data.setdefault("default", []).append({
                    "name": "empty",
                    "size": 0,
                    "length": 0
                })
                break
            elif stripped == "Mail queue is empty.":
                queue_data.setdefault("default", []).append({
                    "name": "empty",
                    "size": 0,
                    "length": 0
                })
                break
            elif stripped.startswith("Mail queue (") and stripped.endswith(") is empty"):
                # Handle named queues like "Mail queue (queue_name) is empty"
                start = stripped.find("(")
                end = stripped.find(")")
                if start >= 0 and end > start:
                    queue_name = stripped[start + 1:end]
                    queue_data.setdefault(queue_name, []).append({
                        "name": "empty",
                        "size": 0,
                        "length": 0
                    })
                continue
            elif stripped.startswith("Total requests:"):
                continue
            elif stripped.startswith("Mail queue") and "is empty" in stripped:
                continue
            elif stripped.startswith("Mail queue") and "bytes" in stripped:
                # Parse size info lines like "The mail queue is 12345 bytes"
                continue
            elif stripped.startswith("Mail queue (") and "bytes" in stripped:
                # Parse named queue size info
                continue
            elif stripped.startswith("Mail queue (") and "is empty" not in stripped:
                continue
            elif stripped == "":
                continue
            elif stripped.find(" ") > 0:
                # Regular queue entry: format is "ID SIZE FROM TO" or similar
                parts = stripped.split()
                if len(parts) >= 2:
                    # Try to determine if this is an ID line
                    id_part = parts[0]
                    if len(id_part) > 0 and id_part[-1] == "*":
                        id_part = id_part[:-1]
                    # If it looks like a queue ID (alphanumeric, 8-12 chars)
                    if id_part.replace(" ", "").isalnum() and (4 <= len(id_part)) and (len(id_part) <= 15):
                        # This is a queue entry line
                        queue_data.setdefault("default", []).append({
                            "name": "mail",
                            "size": 0,  # We can't get exact size without parsing differently
                            "length": 1
                        })
                        continue
        
        # Alternative approach: try to parse with queueid detection
        # Reset and use a cleaner approach
        queue_data = {}
        
        # First try to get a list of queues using postqueue -p for default queue
        res = ctx.run(["postqueue", "-p"], mutates=False)
        if res.rc == 0:
            lines = res.stdout.splitlines()
            count = 0
            for line in lines:
                # Skip header and footer
                if line.startswith("-") or line.startswith("Mail queue") or line.startswith("Total") or line.startswith("--") or line.strip() == "":
                    continue
                if line.strip() != "" and line.find(" ") >= 0:
                    parts = line.strip().split()
                    # Queue ID looks like alphanumeric string 8-12 chars
                    if parts[0].strip() != "" and len(parts[0]) >= 4 and parts[0].isalnum():
                        count += 1
            
            if count > 0:
                queue_data["default"] = [{"name": "mail", "size": 0, "length": count}]
            else:
                queue_data["default"] = [{"name": "empty", "size": 0, "length": 0}]
        
        # Now try to detect named queues
        # Postfix supports multiple queues via queue_directory configuration
        # But for simplicity we'll just report the main queue
        discovery = []
        for queue_name, queues in queue_data.items():
            for mq in queues:
                item = queue_name if queue_name != "" else "default"
                metrics = []
                if mq["name"] == "empty":
                    metrics = ["length"]
                else:
                    metrics = ["length", "size"]
                
                # Set default levels based on Checkmk defaults
                params_default = {}
                if mq["name"] in ["deferred", "mail"]:
                    params_default["deferred"] = (10, 20)
                elif mq["name"] == "active":
                    params_default["active"] = (200, 300)
                else:
                    params_default[mq["name"]] = (10, 20)
                
                discovery.append({
                    "item": item,
                    "params": params_default,
                    "metrics": metrics
                })
        
        return {"changed": False, "msg": "discovered %d queues" % len(discovery),
                "data": {"discovery": discovery}}
    
    # CHECK MODE
    item = params.get("item", "default")
    res = ctx.run(["postqueue", "-p"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "postqueue command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    count = 0
    for line in lines:
        # Skip header and footer
        if line.startswith("-") or line.startswith("Mail queue") or line.startswith("Total") or line.startswith("--") or line.strip() == "":
            continue
        if line.strip() != "" and line.find(" ") >= 0:
            parts = line.strip().split()
            if parts[0].strip() != "" and len(parts[0]) >= 4 and parts[0].isalnum():
                count += 1
    
    # Determine queue name based on item
    queue_name = item if item != "default" else "mail"
    if count == 0:
        queue_name = "empty"
    
    # Get thresholds from params
    # Map queue names to params keys
    param_key = queue_name
    if queue_name == "mail":
        param_key = "deferred"
    
    warn = None
    crit = None
    if param_key in params:
        threshold_tuple = params[param_key]
        if isinstance(threshold_tuple, (list, tuple)) and len(threshold_tuple) == 2:
            warn = threshold_tuple[0]
            crit = threshold_tuple[1]
        else:
            # Handle old style (warn, crit) as tuple
            warn = threshold_tuple[0]
            crit = threshold_tuple[1]
    else:
        # Use default thresholds from Checkmk
        if queue_name == "active":
            warn = 200
            crit = 300
            param_key = "active"
        else:
            warn = 10
            crit = 20
            param_key = "deferred"
    
    # Determine state
    state = "OK"
    msg_parts = []
    
    # Check levels
    if crit != None and count >= crit:
        state = "CRIT"
    elif warn != None and count >= warn:
        state = "WARN"
    
    # Format message
    if queue_name == "empty":
        msg = "The mailqueue is empty"
    else:
        msg = "%s queue length: %d" % (queue_name, count)
    
    # Build metrics
    metrics = {}
    if queue_name != "empty":
        # For length metric, use different names based on queue name
        if queue_name == "active":
            metrics["mail_queue_active_length"] = count
        else:
            metrics["length"] = count
    else:
        metrics["length"] = 0
    
    # For size, we can try to estimate but it's not available from postqueue -p output
    # Postfix agent plugins normally read queue directory sizes, but postqueue -p doesn't provide size
    # So we'll report only length
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}