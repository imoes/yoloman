def main(ctx, params):
    # IBM SVC enclosure temperature check
    # This is a special-agent check that connects to IBM SVC storage over SSH
    # and reads enclosure statistics (temperature, power, etc.)
    
    host = params.get("host", "localhost")
    community = params.get("community", "")
    
    # Probe for IBM SVC: check if the svcinfo command can be run via SSH
    # The data comes from 'svcinfo -nohup lsenclosure' over SSH
    # We need to discover if there's an SVC device to query
    
    if params.get("_discover"):
        # Discovery: try to connect to the SVC and list enclosures
        svc_cmd = [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            host, "svcinfo", "-nohup", "lsenclosure"
        ]
        res = ctx.run(svc_cmd, mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "no IBM SVC enclosure found",
                    "data": {"discovery": []}}
        
        # Parse svcinfo lsenclosure output
        # Expected format (colon-separated): enclosure_id:stat_name:stat_current:stat_peak:stat_peak_time
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(":")
            # We expect lines like: "1:temp_c:22:22:140410113246"
            if len(parts) >= 5:
                enclosure_id = parts[0]
                stat_name = parts[1]
                if stat_name == "temp_c":
                    discovery.append({
                        "item": enclosure_id,
                        "params": {"levels": (35.0, 40.0)},
                        "metrics": ["temperature"]
                    })
        
        return {"changed": False, 
                "msg": "discovered %d enclosures with temperature" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    levels = params.get("levels", (35.0, 40.0))
    warn = levels[0] if type(levels) == "list" or type(levels) == "tuple" else 35.0
    crit = levels[1] if type(levels) == "list" or type(levels) == "tuple" else 40.0
    
    # Query the SVC for enclosure statistics
    svc_cmd = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        host, "svcinfo", "-nohup", "lsenclosure", "-delim", ":"
    ]
    res = ctx.run(svc_cmd, mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "unable to query IBM SVC",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse output to find temperature for the specific enclosure
    temp_c = None
    for line in res.stdout.splitlines():
        parts = line.split(":")
        if len(parts) >= 5:
            enclosure_id = parts[0]
            stat_name = parts[1]
            if enclosure_id == item and stat_name == "temp_c":
                temp_c = int(parts[2])
                break
    
    if temp_c == None:
        return {"changed": False, "msg": "no temperature data for enclosure " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply temperature thresholds
    state = "OK"
    if temp_c >= crit:
        state = "CRIT"
    elif temp_c >= warn:
        state = "WARN"
    
    return {"changed": False,
            "msg": "Temperature: %d C" % temp_c,
            "data": {
                "state": state,
                "metrics": {"temperature": temp_c},
                "details": ""
            }}