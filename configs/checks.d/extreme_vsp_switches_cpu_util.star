# Module-level constants
DETECT_NETEXTREME_OID = ".1.3.6.1.2.1.1.2.0"
NETEXTREME_VSP_OIDS = [".1.3.6.1.4.1.1916.2", ".1.3.6.1.4.1.2272.2", ".1.3.6.1.4.1.2272.202", ".1.3.6.1.4.1.2272.209", ".1.3.6.1.4.1.2272.220", ".1.3.6.1.4.1.2272.212"]
CPU_UTIL_OID_BASE = ".1.3.6.1.4.1.2272.1.85.10.1.1.2"
CPU_UTIL_DEFAULT_WARN = 80.0
CPU_UTIL_DEFAULT_CRIT = 90.0

def _is_netextreme(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, DETECT_NETEXTREME_OID], mutates=False)
    if res.rc != 0:
        return False
    output = res.stdout.strip()
    for oid_prefix in NETEXTREME_VSP_OIDS:
        if output.startswith(oid_prefix):
            return True
    return False

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        # Only discover if device is a NetExtreme VSP switch
        if not _is_netextreme(ctx, community, host):
            return {"changed": False, "msg": "discovered 0 items (not a NetExtreme VSP switch)",
                    "data": {"discovery": []}}
        
        # Try to fetch CPU utilization to confirm service availability
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, CPU_UTIL_OID_BASE], mutates=False)
        if res.rc != 0 or not res.stdout.strip().endswith(": INTEGER:"):
            # No CPU utilization data available
            return {"changed": False, "msg": "discovered 0 items (no CPU utilization data)",
                    "data": {"discovery": []}}
        
        # Single service, no item (item will be None)
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {"util": (CPU_UTIL_DEFAULT_WARN, CPU_UTIL_DEFAULT_CRIT)},
                                        "metrics": ["util"]}]}}
    
    # Check mode (non-discovery)
    # Fetch CPU utilization
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, CPU_UTIL_OID_BASE], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    output = res.stdout.strip()
    # Parse value from "OID = INTEGER: value"
    colon_idx = output.find(": INTEGER:")
    if colon_idx == -1:
        return {"changed": False, "msg": "Unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = output[colon_idx + len(": INTEGER:"):]
    value_str = value_part.strip()
    
    # Guard: check if value_str is numeric before converting
    util = 0.0
    if value_str.isdigit():
        util = float(value_str)
    else:
        return {"changed": False, "msg": "Cannot parse CPU utilization value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract thresholds
    warn, crit = params.get("util", (CPU_UTIL_DEFAULT_WARN, CPU_UTIL_DEFAULT_CRIT))
    
    # Determine state
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False, "msg": "CPU utilization: %f%%" % util,
            "data": {"state": state, "metrics": {"util": util}, "details": ""}}
