# ===== Starlark check module for emerson_temp =====

# Module-level constants (no imports, no classes, no lambdas)
_DISCOVER_MAX_ITEMS = 2
_OFFLINE_THRESHOLD = -273000

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the SNMP tree for Emerson temperature sensors
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk base OID .1.3.6.1.4.1.6302.2.1.2.7 (temperature table)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.6302.2.1.2.7"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        discovery = []
        lines = res.stdout.splitlines() if res.stdout else []
        
        # Process each line: OID = STRING: <value>
        for line in lines:
            if not line.strip():
                continue
            
            # Split on " = " to separate OID and value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            
            oid_val = parts[1]
            
            # Extract numeric value (format: STRING: "-123456" or similar)
            # Look for a quoted string or bare number after " = "
            val_str = oid_val.strip()
            
            # Handle cases like "INTEGER: 25000", "STRING: 25000", etc.
            # Extract the numeric part
            idx = val_str.find(": ")
            if idx >= 0:
                val_str = val_str[idx+2:].strip()
            
            # Remove quotes if present
            if val_str.startswith('"') and val_str.endswith('"'):
                val_str = val_str[1:-1]
            
            # Skip if not a valid integer
            if not val_str.lstrip('-').isdigit():
                continue
            
            temp_millidegree = int(val_str)
            
            # Only include sensors with temperature >= -273000 (not offline)
            if temp_millidegree >= _OFFLINE_THRESHOLD:
                idx = len(discovery)
                if idx >= _DISCOVER_MAX_ITEMS:
                    break
                # Default params: levels from Checkmk default
                discovery.append({
                    "item": str(idx),
                    "params": {"levels": (40.0, 50.0)},
                    "metrics": ["temperature"]
                })
        
        msg = "discovered %d sensors" % len(discovery)
        return {"changed": False, "msg": msg, "data": {"discovery": discovery}}
    
    # Check mode: single item check
    item = params.get("item", "")
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    item_index = int(item)
    
    # Gather data via SNMP (read only)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get specific OID: base + .7 + .(item_index+1)
    # Note: Checkmk uses 0-based indices but SNMP is 1-based (1.0, 2.0, etc.)
    # So we use index item_index+1 in the SNMP tree
    base_oid = ".1.3.6.1.4.1.6302.2.1.2.7"
    oid = base_oid + "." + str(item_index + 1)
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, oid
    ], mutates=False)
    
    # If SNMP fails or returns no data, report UNKNOWN
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP result
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "cannot parse SNMP response for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    val_str = parts[1].strip()
    
    # Extract numeric value
    idx = val_str.find(": ")
    if idx >= 0:
        val_str = val_str[idx+2:].strip()
    
    # Remove quotes if present
    if val_str.startswith('"') and val_str.endswith('"'):
        val_str = val_str[1:-1]
    
    # Validate and convert to integer
    if not val_str.lstrip('-').isdigit():
        return {
            "changed": False,
            "msg": "invalid temperature value for sensor %s: %s" % (item, val_str),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    temp_millidegree = int(val_str)
    
    # Check offline condition
    if temp_millidegree < _OFFLINE_THRESHOLD:
        return {
            "changed": False,
            "msg": "Sensor offline",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Convert to degrees Celsius
    temp = float(temp_millidegree) / 1000.0
    
    # Get thresholds
    # Default from Checkmk: levels=(40.0, 50.0)
    levels = params.get("levels", (40.0, 50.0))
    if isinstance(levels, (list, tuple)) and len(levels) >= 2:
        warn = float(levels[0])
        crit = float(levels[1])
    else:
        warn = 40.0
        crit = 50.0
    
    # Determine state (Checkmk's check_temperature uses upper bounds)
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message (Checkmk style)
    msg = "Temperature: %f C" % temp
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }
