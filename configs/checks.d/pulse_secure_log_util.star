def main(ctx, params):
    # Discovery mode: check if the Pulse Secure log utilization metric is present
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.12532.1"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovery failed",
                "data": {"discovery": []}
            }
        
        # Look for the log utilization value (scalar .1.3.6.1.4.1.12532.1)
        for line in res.stdout.splitlines():
            line = line.strip()
            if line:
                # Format: .1.3.6.1.4.1.12532.1 = INTEGER: <value>
                if line.startswith(".1.3.6.1.4.1.12532.1") and "INTEGER:" in line:
                    return {
                        "changed": False,
                        "msg": "discovered 1 service",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": ["log_file_utilization"]}]}
                    }
        
        # No metric found
        return {
            "changed": False,
            "msg": "no Pulse Secure log utilization data found",
            "data": {"discovery": []}
        }

    # Check mode
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.12532.1"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve log utilization data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the single value
    line = res.stdout.strip()
    if not line.startswith(".1.3.6.1.4.1.12532.1") or "INTEGER:" not in line:
        return {
            "changed": False,
            "msg": "unexpected SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract value after "INTEGER:"
    parts = line.split("INTEGER:")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "could not parse INTEGER value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[1].strip()
    # Guard: check if value_str is numeric before converting
    if not value_str:
        return {
            "changed": False,
            "msg": "empty log utilization value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    # Allow optional leading +/- sign and digits
    clean_str = value_str.lstrip("+-")
    if not clean_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid log utilization value: %s" % value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    log_utilization = int(value_str)
    
    # Determine state using default thresholds from Checkmk (no explicit params provided)
    # Default warn: 80%, crit: 90%
    warn = 80
    crit = 90
    if log_utilization >= crit:
        state = "CRIT"
    elif log_utilization >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Percentage of log file used: %d%%" % log_utilization,
        "data": {
            "state": state,
            "metrics": {"log_file_utilization": log_utilization},
            "details": ""
        }
    }
