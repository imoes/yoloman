def main(ctx, params):
    # Determine if we are in discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: read SNMP data
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # ClusterHealth OID: .1.3.6.1.4.1.12124.1.1.2 (second OID in first tree)
    cluster_health_oid = ".1.3.6.1.4.1.12124.1.1.2"
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, cluster_health_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse snmpget output: "OID = STRING: value" or "OID = INTEGER: value"
    output = res.stdout.strip()
    if not output:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Extract value after ": "
    colon_idx = output.rfind(": ")
    if colon_idx == -1:
        return {
            "changed": False,
            "msg": "invalid SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Guard before parsing: ensure we have digits only (handle possible negative signs for error cases)
    value_str = output[colon_idx + 2:].strip()
    if not value_str:
        return {
            "changed": False,
            "msg": "empty status value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Check if value_str is a valid integer representation (allowing optional minus sign)
    # Use string methods instead of try/except
    status_str = value_str.lstrip("-")
    if not status_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid status value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse status
    status = int(value_str)
    
    # Status mapping: 0=ok, 1=attn, 2=down, 3=invalid
    statusmap = ("ok", "attn", "down", "invalid")
    if status >= len(statusmap):
        return {
            "changed": False,
            "msg": "ClusterHealth reports unidentified status %s" % str(status),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Determine state
    state = "OK" if status == 0 else "CRIT"
    
    return {
        "changed": False,
        "msg": "ClusterHealth reports status %s" % statusmap[status],
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
