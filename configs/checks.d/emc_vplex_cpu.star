def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.1139.21.2.2.3.1.1"  # VP-CPU-MIB::vpCpuUtilizationPerDirector
        
        # Use snmpwalk to fetch all CPU director utilizations
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)
        
        if res.rc != 0:
            # If SNMP fails, assume no data available - return empty discovery
            return {"changed": False, "msg": "SNMP query failed", "data": {"discovery": []}}
        
        # Parse SNMP output: lines look like ".1.3.6.1.4.1.1139.21.2.2.3.1.1.1 = INTEGER: 75"
        items = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            # Extract value after " = INTEGER:"
            idx = stripped.find(" = INTEGER: ")
            if idx == -1:
                continue
            value_part = stripped[idx + len(" = INTEGER: "):]
            # Guard instead of try/except: check if value_part is digit-only
            director_id = ""
            util = 0
            parts = stripped[:idx].rsplit(".", 1)
            if len(parts) == 2:
                director_id = parts[1]
            if value_part.isdigit():
                util = int(value_part)
                items.append({
                    "item": director_id,
                    "params": {"warn": 90.0, "crit": 95.0},
                    "metrics": ["cpu_util"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d CPU directors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode for single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.1139.21.2.2.3.1.1"  # VP-CPU-MIB::vpCpuUtilizationPerDirector
    
    # Construct full OID for specific item
    full_oid = base_oid + "." + item
    
    # Use snmpget for specific OID
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        full_oid
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "CPU data not available for director " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse result: ".1.3.6.1.4.1.1139.21.2.2.3.1.1.X = INTEGER: 75"
    stripped = res.stdout.strip()
    idx = stripped.find(" = INTEGER: ")
    if idx == -1:
        return {
            "changed": False,
            "msg": "Could not parse SNMP output for director " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_part = stripped[idx + len(" = INTEGER: "):]
    if not value_part.isdigit():
        return {
            "changed": False,
            "msg": "Invalid utilization value for director " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    util = int(value_part)
    
    # Calculate CPU utilization: Checkmk source uses max(100 - util, 0)
    # The SNMP value appears to be "idle" percentage, so actual CPU = 100 - idle
    cpu_util = max(100 - util, 0)
    
    # Get thresholds from params with Checkmk defaults
    levels = params.get("levels", (90.0, 95.0))
    warn = levels[0]
    crit = levels[1]
    
    # Determine state based on thresholds
    if cpu_util >= crit:
        state = "CRIT"
    elif cpu_util >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "CPU utilization: %d%%" % cpu_util,
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu_util},
            "details": ""
        }
    }
