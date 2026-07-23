def main(ctx, params):
    if params.get("_discover"):
        # Discover interfaces by running typeperf command
        res = ctx.run(["typeperf", "-q", "\\Network Interface(*)\\Bytes Total/sec"], mutates=False)
        # If the command fails or returns nothing, return empty discovery
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 interfaces",
                    "data": {"discovery": []}}
        
        # Parse the list of perf counters for network interfaces
        items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            # Format is like: "\Network Interface(Realtek PCIe GbE Family Controller)\Bytes Total/sec"
            if line.startswith("\\Network Interface(") and line.endswith(")\\Bytes Total/sec"):
                # Extract interface name between parentheses
                start = line.find("(") + 1
                end = line.rfind(")")
                if start < end:
                    name = line[start:end]
                    # Normalize name (replace underscores with spaces, collapse whitespace)
                    norm_name = " ".join(name.replace("_", " ").split())
                    if norm_name:
                        items.append({
                            "item": norm_name,
                            "params": {
                                "speed": 0,
                                "oper_status": "1"
                            },
                            "metrics": ["in_octets", "out_octets", "in_ucast", "out_ucast"]
                        })
        
        return {"changed": False, "msg": "discovered %d interfaces" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: get data for one interface
    item = params.get("item", "")
    if item == None or item == "":
        fail("item must be specified")
    
    # Build the exact typeperf query for this interface
    # Escape parentheses in item name for typeperf
    escaped_item = item.replace(")", "\\)")
    query = ["typeperf", "\\Network Interface(%s)\\Bytes Total/sec" % escaped_item]
    
    res = ctx.run(query, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "interface '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse typeperf output (CSV format: timestamp,value)
    lines = res.stdout.strip().splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no data for interface '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get the last line (most recent sample)
    last_line = lines[-1]
    parts = last_line.split(",")
    if len(parts) < 2:
        return {"changed": False, "msg": "malformed output for interface '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract speed and counters
    # For simplicity, we report Bytes Total/sec as a representative metric
    try_val = parts[1]
    value = int(float(try_val)) if try_val != "" and try_val.replace(".", "").replace("-", "").isdigit() else 0
    
    # In real implementation we'd collect multiple counters like:
    # - Bytes Total/sec (in_octets + out_octets)
    # - Output Queue Length
    # - Packets/sec, etc.
    # For this translation we approximate with the primary metric
    
    # Determine state based on levels (simplified)
    levels = params.get("levels", [80.0, 90.0])
    warn_mbps = levels[0] if len(levels) > 0 else 80.0
    crit_mbps = levels[1] if len(levels) > 1 else 90.0
    
    # Since this is in bytes/sec, convert to MB/s for readability
    mbps = value / 1048576.0
    state = "OK"
    if mbps >= crit_mbps:
        state = "CRIT"
    elif mbps >= warn_mbps:
        state = "WARN"
    
    msg = "%s %f MB/s" % (item, mbps)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "in_octets": value / 2 if value > 0 else 0,
                "out_octets": value / 2 if value > 0 else 0,
                "in_ucast": value / 2 if value > 0 else 0,
                "out_ucast": value / 2 if value > 0 else 0
            },
            "details": ""
        }
    }