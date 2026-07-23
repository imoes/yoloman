# F5 BIG-IP Cluster Config Sync check (v11+)
# Read-only Starlark module for yolo-man agent

CONFIG_SYNC_DEFAULT_PARAMETERS = {
    "0": 3,
    "1": 0,
    "2": 1,
    "3": 0,
    "4": 2,
    "5": 2,
    "6": 2,
    "7": 1,
    "8": 2,
    "9": 2,
}

CONFIG_SYNC_STATE_NAMES = {
    "0": "Unknown",
    "1": "Syncing",
    "2": "Need Manual Sync",
    "3": "In Sync",
    "4": "Sync Failed",
    "5": "Sync Disconnected",
    "6": "Standalone",
    "7": "Awaiting Initial Sync",
    "8": "Incompatible Version",
    "9": "Partial Sync",
}

STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def main(ctx, params):
    # Discover mode: single service for all F5 BIG-IP v11+ devices
    if params.get("_discover"):
        # Check if device is F5 BIG-IP v11+ by querying sysObjectID and product info
        res = ctx.run([
            "snmpget", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.2.1.1.2.0",  # sysObjectID
            ".1.3.6.1.4.1.3375.2.1.4.1.0",  # sysProductName
            ".1.3.6.1.4.1.3375.2.1.4.2.0",  # sysProductVersion
        ], mutates=False)
        
        # Guard: if SNMP probe failed or output empty, no F5 BIG-IP device
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "discovered 0 items (SNMP probe failed)",
                    "data": {"discovery": []}}
        
        output = res.stdout
        has_f5_oid = False
        has_bigip_product = False
        version_ok = False
        
        # Check for F5 BIG-IP OID (.1.3.6.1.4.1.3375.2)
        if ".1.3.6.1.4.1.3375.2" in output:
            has_f5_oid = True
        
        # Check for big-ip product name
        if "big-ip" in output.lower():
            has_bigip_product = True
        
        # Check version >= 11 (regex pattern: ^((1[1-9])|([2-9]\d))(\.\d+)*$)
        # Extract version from output
        version_str = ""
        for line in output.splitlines():
            if ".1.3.6.1.4.1.3375.2.1.4.2.0" in line:
                parts = line.split(" = ")
                if len(parts) >= 2:
                    version_str = parts[1].strip().strip('"')
                    break
        
        # Simple version check: must start with 11-99 followed by dot or be 11.x
        if version_str != "":
            # Split version string to get major version
            version_parts = version_str.split(".")
            if len(version_parts) > 0:
                major_str = version_parts[0]
                # Guard instead of try/except: only process if all digits
                if major_str.isdigit():
                    major = int(major_str)
                    if major >= 11:
                        version_ok = True
        
        # If F5 BIG-IP v11+, discover one service
        if has_f5_oid and has_bigip_product and version_ok:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
    
    # Check mode: get config sync status from SNMP
    # .1.3.6.1.4.1.3375.2.1.14.1.1.0 = sysCmSyncStatusId
    # .1.3.6.1.4.1.3375.2.1.14.1.2.0 = sysCmSyncStatusStatus
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.3375.2.1.14.1.1.0",  # sysCmSyncStatusId
        ".1.3.6.1.4.1.3375.2.1.14.1.2.0",  # sysCmSyncStatusStatus
    ], mutates=False)
    
    # Guard: if SNMP probe failed or output empty
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "SNMP probe failed",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    # Parse output: look for the two OIDs
    state_id = ""
    state_description = ""
    
    for line in res.stdout.splitlines():
        if ".1.3.6.1.4.1.3375.2.1.14.1.1.0" in line and " = " in line:
            parts = line.split(" = ")
            if len(parts) >= 2:
                state_id = parts[1].strip().strip('"')
        elif ".1.3.6.1.4.1.3375.2.1.14.1.2.0" in line and " = " in line:
            parts = line.split(" = ")
            if len(parts) >= 2:
                state_description = parts[1].strip().strip('"')
    
    # Guard: if state_id is empty
    if state_id == "":
        return {"changed": False, "msg": "config sync status not available",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    # Map state using default parameters and state names
    status = CONFIG_SYNC_DEFAULT_PARAMETERS.get(state_id, 2)  # Default to CRIT if unknown
    status_name = CONFIG_SYNC_STATE_NAMES.get(state_id, "Unknown")
    
    # Determine Checkmk state from numeric status
    # 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN in Checkmk State enum
    if status == 0:
        check_state = STATE_OK
    elif status == 1:
        check_state = STATE_WARN
    elif status == 2:
        check_state = STATE_CRIT
    else:
        check_state = STATE_UNKNOWN
    
    # Build info text
    infotext = status_name
    if status_name != state_description and state_description != "":
        infotext += " - " + state_description
    
    # Return result
    return {"changed": False, "msg": infotext,
            "data": {"state": check_state, "metrics": {}, "details": ""}}
