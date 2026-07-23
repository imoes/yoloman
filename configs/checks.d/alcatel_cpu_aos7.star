# Constants for SNMP OIDs
ALCATEL_SYS_OID = ".1.3.6.1.2.1.1.2.0"
ALCATEL_AOS7_OID = ".1.3.6.1.4.1.6486.801"
CPU_OID_AOS7 = ".1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1.15"

# Threshold defaults (from Checkmk source: levels_upper=("fixed", (90.0, 95.0)))
DEFAULT_WARN = 90.0
DEFAULT_CRIT = 95.0

def main(ctx, params):
    # Determine if we're in discovery mode
    if params.get("_discover"):
        # Detect if this is an Alcatel AOS7 device
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ALCATEL_SYS_OID],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpget failed", "data": {"discovery": []}}
        
        # Parse sysObjectID value (format: OID = STRING: "..." or OID = OID: "...")
        output = res.stdout.strip()
        if output == "" or "=" not in output:
            return {"changed": False, "msg": "could not parse sysObjectID", "data": {"discovery": []}}
        
        # Extract OID value (after the last dot in the assignment)
        parts = output.split(":")
        if len(parts) < 2:
            return {"changed": False, "msg": "could not parse sysObjectID value", "data": {"discovery": []}}
        
        value = ":".join(parts[1:]).strip()
        # Check if it starts with AOS7 OID
        is_aos7 = value.startswith(ALCATEL_AOS7_OID)
        
        # Only discover if device is AOS7
        if not is_aos7:
            return {"changed": False, "msg": "device is not Alcatel AOS7", "data": {"discovery": []}}
        
        # Single-service check: yield one service
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["util"]}]}}

    # Check mode: gather CPU utilization
    # Get community and host from params
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Query CPU OID
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, CPU_OID_AOS7],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpget failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse output: OID = INTEGER: <value>
    output = res.stdout.strip()
    if output == "" or "=" not in output:
        return {"changed": False, "msg": "could not parse CPU OID output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract value (last part after ":")
    parts = output.split(":")
    if len(parts) < 2:
        return {"changed": False, "msg": "could not parse CPU value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = ":".join(parts[1:]).strip()
    
    # Convert to integer (snmpget returns integer)
    if not value_str.isdigit():
        return {"changed": False, "msg": "CPU value is not an integer",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    cpu_percent = int(value_str)
    
    # Get thresholds from params (checkmk defaults: 90.0/95.0)
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    
    # Determine state based on thresholds (upper levels: CRIT if >= crit, WARN if >= warn)
    if cpu_percent >= crit:
        state = "CRIT"
    elif cpu_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message string (Checkmk style: "Total 45%")
    msg = "Total %d%%" % cpu_percent
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"util": float(cpu_percent)}, "details": ""}}
