# Top-level constants for state mapping
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3

def main(ctx, params):
    # Discovery mode: enumerate all archive services
    if params.get("_discover"):
        # Fetch archive status OID: .1.3.6.1.4.1.110901.1.4.1.0
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.110901.1.4.1"
        ], mutates=False)
        
        # Parse output: format is "OID = STRING: <value>"
        # We expect one line like: .1.3.6.1.4.1.110901.1.4.1.0 = STRING: "1"
        discovery_items = []
        for line in res.stdout.splitlines():
            # Extract value after the last space/tab (e.g., "1")
            parts = line.strip().split()
            if len(parts) >= 2:
                value = parts[-1].strip('"')
                # Map to status text
                if value == "1":
                    status = "online"
                elif value == "2":
                    status = "offline"
                elif value == "3":
                    status = "unknown"
                else:
                    status = "unexpected state"
                discovery_items.append({
                    "item": "Manager",
                    "params": {},
                    "metrics": []
                })
                break  # Only one archive manager service
        
        return {
            "changed": False,
            "msg": "discovered %d archive services" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: single item ("Manager")
    item = params.get("item", "")
    if item != "Manager":
        return {
            "changed": False,
            "msg": "no such archive item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch archive status OID
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.110901.1.4.1.0"
    ], mutates=False)
    
    # Parse status value
    status_value = ""
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            status_value = parts[-1].strip('"')
            break
    
    # Map status value to Checkmk state and summary
    if status_value == "1":
        state = "OK"
        summary = "online"
    elif status_value == "2":
        state = "CRIT"
        summary = "offline"
    elif status_value == "3":
        state = "WARN"
        summary = "unknown"
    else:
        state = "UNKNOWN"
        summary = "unexpected state: " + (status_value if status_value else "empty")
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }