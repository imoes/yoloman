def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Query IBM MQ channel status via runmqsc (MQSC command interface)
        # We use 'dis chstatus(*) all' to get all channel statuses
        res = ctx.run(["runmqsc", "-c", "QMGR"], mutates=False)
        # If runmqsc is not installed or QMGR not running, return empty discovery
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 channels", "data": {"discovery": []}}
        
        # Parse the MQSC output to extract channel status entries
        # Format: CHANNEL(name) CHLTYPE(type) STATUS(state) ... etc.
        lines = res.stdout.splitlines()
        discovered = []
        # We look for "AMQ8417: Display Channel Status details" sections
        current_item = {}
        for line in lines:
            line = line.strip()
            if line.startswith("AMQ8417:"):
                # Previous channel is complete if we have one
                if current_item and "CHANNEL" in current_item:
                    item_name = current_item["CHANNEL"]
                    # Only add if it's a channel (contains ':')
                    if ":" in item_name:
                        discovered.append({"item": item_name, "params": {}, "metrics": []})
                current_item = {}
            elif line.startswith("CHANNEL(") or " CHANNEL(" in line:
                # Extract channel name
                start = line.find("CHANNEL(")
                if start == -1:
                    start = line.find(" CHANNEL(")
                if start != -1:
                    start += len("CHANNEL(")
                    end = line.find(")", start)
                    if end != -1:
                        current_item["CHANNEL"] = line[start:end]
            elif line.startswith("CHLTYPE(") or " CHLTYPE(" in line:
                start = line.find("CHLTYPE(")
                if start == -1:
                    start = line.find(" CHLTYPE(")
                if start != -1:
                    start += len("CHLTYPE(")
                    end = line.find(")", start)
                    if end != -1:
                        current_item["CHLTYPE"] = line[start:end]
            elif line.startswith("STATUS(") or " STATUS(" in line:
                start = line.find("STATUS(")
                if start == -1:
                    start = line.find(" STATUS(")
                if start != -1:
                    start += len("STATUS(")
                    end = line.find(")", start)
                    if end != -1:
                        current_item["STATUS"] = line[start:end]
            elif line.startswith("XMITQ(") or " XMITQ(" in line:
                start = line.find("XMITQ(")
                if start == -1:
                    start = line.find(" XMITQ(")
                if start != -1:
                    start += len("XMITQ(")
                    end = line.find(")", start)
                    if end != -1:
                        current_item["XMITQ"] = line[start:end]
        
        # Handle last channel if exists
        if current_item and "CHANNEL" in current_item:
            item_name = current_item["CHANNEL"]
            if ":" in item_name:
                discovered.append({"item": item_name, "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d channels" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # === CHECK MODE ===
    item = params.get("item", "")
    # Query channel status
    res = ctx.run(["runmqsc", "-c", "QMGR"], mutates=False)
    
    # Parse to find the specific channel
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Unable to query channel status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    channel_data = {}
    current_item = {}
    
    for line in lines:
        line = line.strip()
        if line.startswith("AMQ8417:"):
            # New channel section starts
            if current_item and "CHANNEL" in current_item:
                if current_item["CHANNEL"] == item:
                    channel_data = current_item
                current_item = {}
        elif line.startswith("CHANNEL(") or " CHANNEL(" in line:
            start = line.find("CHANNEL(")
            if start == -1:
                start = line.find(" CHANNEL(")
            if start != -1:
                start += len("CHANNEL(")
                end = line.find(")", start)
                if end != -1:
                    current_item["CHANNEL"] = line[start:end]
        elif line.startswith("CHLTYPE(") or " CHLTYPE(" in line:
            start = line.find("CHLTYPE(")
            if start == -1:
                start = line.find(" CHLTYPE(")
            if start != -1:
                start += len("CHLTYPE(")
                end = line.find(")", start)
                if end != -1:
                    current_item["CHLTYPE"] = line[start:end]
        elif line.startswith("STATUS(") or " STATUS(" in line:
            start = line.find("STATUS(")
            if start == -1:
                start = line.find(" STATUS(")
            if start != -1:
                start += len("STATUS(")
                end = line.find(")", start)
                if end != -1:
                    current_item["STATUS"] = line[start:end]
        elif line.startswith("XMITQ(") or " XMITQ(" in line:
            start = line.find("XMITQ(")
            if start == -1:
                start = line.find(" XMITQ(")
            if start != -1:
                start += len("XMITQ(")
                end = line.find(")", start)
                if end != -1:
                    current_item["XMITQ"] = line[start:end]
    
    # Handle last channel if it's the target
    if current_item and "CHANNEL" in current_item and current_item["CHANNEL"] == item:
        channel_data = current_item
    
    # If item not found and queue manager is RUNNING, it vanished
    # Check for queue manager status in the output
    qmgr_running = False
    for line in lines:
        if line.startswith("QMNAME("):
            qmgr_running = True
            break
    
    if not channel_data and qmgr_running:
        return {
            "changed": False,
            "msg": "Channel %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract status and build result
    status = channel_data.get("STATUS", "INACTIVE")
    
    # Status mapping (same as Checkmk)
    status_map = {
        "INACTIVE": ("inactive", 0),
        "INITIALIZING": ("initializing", 0),
        "BINDING": ("binding", 0),
        "STARTING": ("starting", 0),
        "RUNNING": ("running", 0),
        "RETRYING": ("retrying", 1),
        "STOPPING": ("stopping", 0),
        "STOPPED": ("stopped", 2),
    }
    
    wato_key, check_state = status_map.get(status, ("unknown", 3))
    
    # Apply mapped_states if provided (from Checkmk params)
    if "mapped_states" in params:
        mapped_states = params.get("mapped_states", {})
        if wato_key in mapped_states:
            check_state = mapped_states[wato_key]
        elif "mapped_states_default" in params:
            check_state = params.get("mapped_states_default", check_state)
    
    # Build summary message
    chltype = channel_data.get("CHLTYPE", "")
    infotext = "Status: " + status + ", Type: " + chltype
    if "XMITQ" in channel_data:
        infotext += ", Xmitq: " + channel_data["XMITQ"]
    
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state_map[check_state],
            "metrics": {},
            "details": ""
        }
    }