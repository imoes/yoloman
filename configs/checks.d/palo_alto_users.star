# Top-level constant for SNMP OID base
PALO_ALTO_OID_BASE = ".1.3.6.1.4.1.25461.2.1.2.5.1"

def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover") == True:
        # Discovery: always yields one service
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": "ignore"},
                        "metrics": ["num_user", "max_user", "user_perc"]
                    }
                ]
            }
        }
    
    # Check mode
    # Fetch SNMP data: panGPGWUtilizationMaxTunnels (2.0) and panGPGWUtilizationActiveTunnels (3.0)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        PALO_ALTO_OID_BASE
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output lines to extract the two values
    max_users = None
    num_users = None
    for line in res.stdout.splitlines():
        if line == "":
            continue
        # Format: OID = STRING: value
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the numeric suffix from the OID
        suffix = oid_part.rsplit(".", 1)[-1]
        if suffix == "2.0":
            # panGPGWUtilizationMaxTunnels
            value_str = value_part.split(": ")[-1] if ": " in value_part else value_part
            if value_str.isdigit():
                max_users = int(value_str)
        elif suffix == "3.0":
            # panGPGWUtilizationActiveTunnels
            value_str = value_part.split(": ")[-1] if ": " in value_part else value_part
            if value_str.isdigit():
                num_users = int(value_str)
    
    if max_users == None or num_users == None:
        return {
            "changed": False,
            "msg": "could not parse SNMP data for Palo Alto users",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if max_users <= 0:
        return {
            "changed": False,
            "msg": "max users is zero or negative",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    user_perc = float(num_users) / float(max_users) * 100.0
    
    # Extract levels from params; default is "ignore"
    levels = params.get("levels", "ignore")
    abs_levels = None
    perc_levels = None
    
    if levels == "ignore":
        abs_levels = None
        perc_levels = None
    elif type(levels) == "list" and len(levels) >= 2:
        # Handle legacy format: [type, thresholds] where type is "abs_user" or "perc_user"
        level_type = levels[0]
        thresholds = levels[1]
        if level_type == "abs_user" and thresholds != None:
            abs_levels = thresholds
            perc_levels = None
        elif level_type == "perc_user" and thresholds != None:
            abs_levels = None
            perc_levels = thresholds
    else:
        abs_levels = None
        perc_levels = None
    
    # Determine state based on levels
    state = "OK"
    details = ""
    
    # Absolute levels check (upper bounds only)
    if abs_levels != None:
        if len(abs_levels) >= 1 and num_users >= abs_levels[0]:
            state = "WARN"
            details = "absolute users exceed warn threshold"
        if len(abs_levels) >= 2 and num_users >= abs_levels[1]:
            state = "CRIT"
            details = "absolute users exceed crit threshold"
    
    # Relative levels check (upper bounds only)
    if state == "OK" and perc_levels != None:
        if len(perc_levels) >= 1 and user_perc >= perc_levels[0]:
            state = "WARN"
            details = "percentage users exceed warn threshold"
        if len(perc_levels) >= 2 and user_perc >= perc_levels[1]:
            state = "CRIT"
            details = "percentage users exceed crit threshold"
    
    # Build summary
    summary = "Number of logged in users: %f%% - %d of %d" % (user_perc, num_users, max_users)
    
    metrics = {
        "num_user": num_users,
        "max_user": max_users,
        "user_perc": user_perc
    }
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }