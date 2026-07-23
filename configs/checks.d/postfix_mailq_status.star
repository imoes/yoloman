def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["postfix", "mailq"], mutates=False)
        # Parse output: look for lines like:
        # postfix/mailq is running, PID: 1234
        # or error lines like:
        # mail system is not running
        # PID file exists but instance is not running!
        # PID file exists but is not readable
        lines = res.stdout.strip().split("\n")
        items = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Try to detect queue name and status
            # Common formats:
            # "postfix/mailq is running, PID: 1234"
            # "postfix/mailq is not running"
            # "mailq (PID file exists but instance is not running!)"
            # "mailq (PID file exists but is not readable)"
            queue_name = "default"
            status_part = ""
            if "is running, PID:" in line:
                # Extract queue name from first part
                parts = line.split()
                if parts:
                    queue_name = parts[0].split("/")[0] if "/" in parts[0] else parts[0]
                status_part = "running"
            elif "is not running" in line:
                # Could be "mail system is not running" or queue-specific
                if "mail system is not running" in line:
                    continue  # Skip system-wide "not running" entries
                # Queue-specific "not running" - mark as error
                if "PID file exists but instance is not running!" in line:
                    status_part = "PID file exists but instance is not running!"
                elif "PID file exists but is not readable" in line:
                    status_part = "PID file exists but is not readable"
                else:
                    status_part = "is not running"
            elif "(" in line and ")" in line:
                # Format like: mailq (PID file exists but instance is not running!)
                start = line.find("(")
                queue_name = line[:start].strip().split("/")[0]
                status_part = line[start+1:].rstrip(")").strip()
            else:
                continue
            
            # Filter out SystemNotRunning status (skip it in discovery)
            if status_part == "the Postfix mail system is not running":
                continue
            
            # Build item
            item_name = queue_name if queue_name else "default"
            if status_part == "running" or status_part == "":
                items.append({"item": item_name, "params": {}, "metrics": []})
            else:
                # For error statuses, include them in discovery
                items.append({"item": item_name, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d mailqueue instances" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "default")
    res = ctx.run(["postfix", "mailq"], mutates=False)
    
    # Parse the output to find the requested queue
    lines = res.stdout.strip().split("\n")
    status = None
    pid = None
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Check if this line matches our item
        queue_name = item
        if line.startswith(queue_name + "/") or line.startswith(queue_name + " "):
            if "is running, PID:" in line:
                # Extract PID
                parts = line.split("PID:")
                if len(parts) > 1:
                    pid_str = parts[1].strip().split()[0]
                    if pid_str.isdigit():
                        pid = int(pid_str)
                status = "running"
            elif "is not running" in line:
                status = "is not running"
            elif "(" in line and ")" in line:
                start = line.find("(")
                status_part = line[start+1:].rstrip(")").strip()
                if status_part == "PID file exists but instance is not running!" or \
                   status_part == "PID file exists but is not readable":
                    status = status_part
    
    # Check if queue is in system-wide error (not running) and skip
    if status == "the Postfix mail system is not running":
        return {"changed": False, "msg": "Postfix mail system is not running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    # If not found, return UNKNOWN
    if status == None:
        return {"changed": False, "msg": "queue %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Process result
    if status == "running":
        msg = "Status: the Postfix mail system is running"
        if pid != None:
            msg = msg + "; PID: %d" % pid
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "Status: " + status,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}