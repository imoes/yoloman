# Module-level constants (no imports allowed)
SNMP_BASE = ".1.3.6.1.4.1.2544"
OID_CURRENT = ".1.11.2.4.2.2.1.1"
OID_THRESHOLD = ".1.11.2.4.2.2.1.2"
OID_POWER = ".1.11.2.4.2.2.1.3"
OID_UNIT_NAME = ".2.5.5.1.1.1"
OID_INDEX_AID = ".2.5.5.2.1.5"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), SNMP_BASE
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output: lines like ".1.3.6.1.4.1.2544.1.11.2.4.2.2.1.1.101318912  8110"
        # Extract 5-tuples: current, threshold, power, unit_name, index_aid
        records = []
        i = 0
        lines = res.stdout.splitlines()
        while i + 4 < len(lines):
            # Check for consecutive OIDs in expected pattern
            parts0 = lines[i].strip().split()
            parts1 = lines[i+1].strip().split()
            parts2 = lines[i+2].strip().split()
            parts3 = lines[i+3].strip().split()
            parts4 = lines[i+4].strip().split()
            
            # Validate format: [oid, '=', type':', value]
            if len(parts0) >= 3 and len(parts1) >= 3 and len(parts2) >= 3 and len(parts3) >= 3 and len(parts4) >= 3:
                oid0 = parts0[0].rstrip(":")
                oid1 = parts1[0].rstrip(":")
                oid2 = parts2[0].rstrip(":")
                oid3 = parts3[0].rstrip(":")
                oid4 = parts4[0].rstrip(":")
                
                if (oid0.startswith(OID_CURRENT) and 
                    oid1.startswith(OID_THRESHOLD) and 
                    oid2.startswith(OID_POWER) and 
                    oid3.startswith(OID_UNIT_NAME) and 
                    oid4.startswith(OID_INDEX_AID)):
                    
                    current_str = parts0[-1].strip().rstrip('"')
                    threshold_str = parts1[-1].strip().rstrip('"')
                    power_str = parts2[-1].strip().rstrip('"')
                    unit_name = parts3[-1].strip().rstrip('"')
                    index_aid = parts4[-1].strip().rstrip('"')
                    
                    # Ignore non-connected sensors (power_str must be non-empty)
                    if index_aid and power_str:
                        records.append({
                            "current": current_str,
                            "threshold": threshold_str,
                            "power": power_str,
                            "unit_name": unit_name,
                            "index_aid": index_aid
                        })
            
            i += 1
        
        discovery_items = []
        for rec in records:
            item = rec["index_aid"]
            
            # Suggested params (empty as Checkmk source has no levels)
            discovery_items.append({
                "item": item,
                "params": {},
                "metrics": ["current"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode (not discovery)
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), SNMP_BASE
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output for the specific item
    sensor = None
    # Re-scan for complete record matching item
    lines = res.stdout.splitlines()
    i = 0
    while i + 4 < len(lines):
        parts0 = lines[i].strip().split()
        parts1 = lines[i+1].strip().split()
        parts2 = lines[i+2].strip().split()
        parts3 = lines[i+3].strip().split()
        parts4 = lines[i+4].strip().split()
        
        if len(parts0) >= 3 and len(parts1) >= 3 and len(parts2) >= 3 and len(parts3) >= 3 and len(parts4) >= 3:
            oid0 = parts0[0].rstrip(":")
            oid1 = parts1[0].rstrip(":")
            oid2 = parts2[0].rstrip(":")
            oid3 = parts3[0].rstrip(":")
            oid4 = parts4[0].rstrip(":")
            
            if (oid0.startswith(OID_CURRENT) and 
                oid1.startswith(OID_THRESHOLD) and 
                oid2.startswith(OID_POWER) and 
                oid3.startswith(OID_UNIT_NAME) and 
                oid4.startswith(OID_INDEX_AID)):
                
                index_aid = parts4[-1].strip().rstrip('"')
                if index_aid == item:
                    current_str = parts0[-1].strip().rstrip('"')
                    threshold_str = parts1[-1].strip().rstrip('"')
                    power_str = parts2[-1].strip().rstrip('"')
                    unit_name = parts3[-1].strip().rstrip('"')
                    
                    # Only use if valid and connected
                    if index_aid and power_str and current_str.isdigit() and threshold_str.isdigit():
                        current = float(current_str) / 1000.0
                        crit = float(threshold_str) / 1000.0
                        sensor = {"name": unit_name, "current": current, "crit": crit}
                        break
        
        i += 1
    
    # If sensor not found
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply check logic (no levels in Checkmk source, so use sensor's crit as threshold)
    # Checkmk uses check_levels with levels_upper=("fixed", (crit, crit))
    current_val = sensor["current"]
    crit = sensor["crit"]
    
    # Determine state: WARN/CRIT if current >= crit (fixed thresholds)
    if current_val >= crit:
        state = "CRIT"
    else:
        state = "OK"
    
    # Build message string
    msg = "[%s] %f A" % (sensor["name"], current_val)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"current": current_val},
            "details": ""
        }
    }
