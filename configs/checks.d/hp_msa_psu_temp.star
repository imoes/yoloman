def main(ctx, params):
    if params.get("_discover"):
        # Discover PSUs by reading agent data
        res = ctx.run(["cat", "/var/lib/check-mk-agent/spool/hp_msa_psu"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read agent data", 
                    "data": {"discovery": []}}
        
        # Parse the agent output to find PSU items
        psu_items = {}
        current_item = None
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0] == "power-supplies":
                if parts[1] != current_item:
                    current_item = parts[1]
                    psu_items[current_item] = {}
                key = parts[2]
                value = " ".join(parts[3:])
                psu_items[current_item][key] = value
        
        # Find items with valid temperature data (dctemp != "0")
        discovery = []
        for item in psu_items:
            data = psu_items[item]
            if data.get("dctemp") != "0":
                discovery.append({
                    "item": item,
                    "params": {"levels": (40.0, 45.0)},
                    "metrics": ["temp"]
                })
        
        return {"changed": False, "msg": "discovered %d power supplies" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode - monitor temperature for one PSU
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/spool/hp_msa_psu"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read agent data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse agent data for the specific item
    data = {}
    current_item = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "power-supplies":
            if parts[1] != current_item:
                current_item = parts[1]
                data = {}
            if current_item == item:
                key = parts[2]
                value = " ".join(parts[3:])
                data[key] = value
    
    if not data:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_str = data.get("dctemp", "0")
    # Guard instead of try/except
    temp = float(temp_str) / 10.0 if temp_str.isdigit() or (temp_str.find('.') != -1 and temp_str.replace('.', '').replace('-', '').isdigit()) else 0.0
    
    # Apply temperature levels (Checkmk uses warn/crit for upper thresholds)
    warn, crit = params.get("levels", (40.0, 45.0))
    
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Temperature: %f C" % temp
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp}, "details": ""}}