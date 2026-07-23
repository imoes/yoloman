def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["redis-cli", "info", "Clients"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no redis-cli or no clients data", "data": {"discovery": []}}
        
        # Parse the clients section
        clients_data = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or not ":" in line:
                continue
            key, value = line.split(":", 1)
            value = value.strip()
            # Only integer metrics matter for discovery
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                clients_data[key] = int(value)
        
        # If we have clients data, create one discovery item
        if clients_data:
            return {"changed": False, "msg": "discovered 1 Redis clients instance", 
                    "data": {"discovery": [
                        {"item": "", "params": {
                            "connected_upper": ("no_levels", None),
                            "connected_lower": ("no_levels", None),
                            "output_upper": ("no_levels", None),
                            "output_lower": ("no_levels", None),
                            "input_upper": ("no_levels", None),
                            "input_lower": ("no_levels", None),
                            "blocked_upper": ("no_levels", None),
                            "blocked_lower": ("no_levels", None),
                        }, "metrics": [
                            "clients_connected", 
                            "clients_output", 
                            "clients_input", 
                            "clients_blocked"
                        ]}
                    ]}}
        else:
            return {"changed": False, "msg": "no clients data found", "data": {"discovery": []}}
    
    # Check mode
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "no such instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get Redis clients data
    res = ctx.run(["redis-cli", "info", "Clients"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "could not get clients info",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the clients section
    clients_data = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or not ":" in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
            clients_data[key] = int(value)
    
    # If no clients data, report UNKNOWN
    if not clients_data:
        return {"changed": False, "msg": "no clients data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract values
    connected = clients_data.get("connected_clients", 0)
    output = clients_data.get("client_longest_output_list", 0)
    input_buf = clients_data.get("client_biggest_input_buf", 0)
    blocked = clients_data.get("blocked_clients", 0)
    
    # Get threshold parameters (Checkmk defaults)
    def parse_levels(levels_tuple):
        if levels_tuple == None:
            return None, None
        if type(levels_tuple) == "string" and levels_tuple == "no_levels":
            return None, None
        if type(levels_tuple) == "list" and len(levels_tuple) == 2:
            return levels_tuple[0], levels_tuple[1]
        return None, None
    
    connected_upper_warn, connected_upper_crit = parse_levels(params.get("connected_upper"))
    connected_lower_warn, connected_lower_crit = parse_levels(params.get("connected_lower"))
    output_upper_warn, output_upper_crit = parse_levels(params.get("output_upper"))
    output_lower_warn, output_lower_crit = parse_levels(params.get("output_lower"))
    input_upper_warn, input_upper_crit = parse_levels(params.get("input_upper"))
    input_lower_warn, input_lower_crit = parse_levels(params.get("input_lower"))
    blocked_upper_warn, blocked_upper_crit = parse_levels(params.get("blocked_upper"))
    blocked_lower_warn, blocked_lower_crit = parse_levels(params.get("blocked_lower"))
    
    # Helper function for level checking
    def check_levels(value, warn, crit):
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
        if crit != None and value <= crit:
            return "CRIT"
        if warn != None and value <= warn:
            return "WARN"
        return "OK"
    
    # Determine states
    state_connected = check_levels(connected, connected_upper_warn, connected_upper_crit)
    state_output = check_levels(output, output_upper_warn, output_upper_crit)
    state_input = check_levels(input_buf, input_upper_warn, input_upper_crit)
    state_blocked = check_levels(blocked, blocked_upper_warn, blocked_upper_crit)
    
    # Determine overall state
    states = [state_connected, state_output, state_input, state_blocked]
    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg_parts = []
    if connected != None:
        msg_parts.append("connected: %d" % connected)
    if output != None:
        msg_parts.append("output_list: %d" % output)
    if input_buf != None:
        msg_parts.append("input_buf: %d" % input_buf)
    if blocked != None:
        msg_parts.append("blocked: %d" % blocked)
    msg = ", ".join(msg_parts) if msg_parts else "no clients data"
    
    # Build metrics
    metrics = {}
    if connected != None:
        metrics["clients_connected"] = connected
    if output != None:
        metrics["clients_output"] = output
    if input_buf != None:
        metrics["clients_input"] = input_buf
    if blocked != None:
        metrics["clients_blocked"] = blocked
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}