# Fast LTA Headunit Status check module (read-only)
# Translated from Checkmk plugin cmk.plugins.fast_lta.agent_based.fast_lta_headunit

# SNMP OIDs
BASE_OID = ".1.3.6.1.4.1.27417.2"
OID_HEADUNIT_STATUS = ".1"
OID_APP_READ_ONLY_STATUS = ".2"
OID_REPLICATION_MODE = ".1.3.6.1.4.1.27417.2.1.0"

# Status mappings
HEADUNIT_STATUS_MAP = {
    "-1": "workerDefect",
    "-2": "workerNotStarted",
    "2": "workerBooting",
    "3": "workerRfRRunning",
    "10": "appBooting",
    "20": "appNoCubes",
    "30": "appVirginCubes",
    "40": "appRfrPossible",
    "45": "appRfrMixedCubes",
    "50": "appRfrActive",
    "60": "appReady",
    "65": "appMixedCubes",
    "70": "appReadOnly",
    "75": "appEnterpriseCubes",
    "80": "appEnterpriseMixedCubes",
}

REPLICATION_MODE_MAP = {
    "0": "Slave",
    "1": "Master",
    "255": "standalone",
}


def main(ctx, params):
    # Discovery mode: check if Fast LTA Headunit section exists
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-Ovq", BASE_OID], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 items (no Fast LTA Headunit data)",
                "data": {"discovery": []},
            }
        # Check for presence of Fast LTA Headunit data (existence checks from detection)
        has_headunit = res.stdout.find("1.3.6.1.4.1.27417.2.1") != -1 or res.stdout.find("1.3.6.1.4.1.27417.2.1.0") != -1
        has_os = res.stdout.find("1.3.6.1.4.1.8072.3.2.10") != -1
        if has_headunit and has_os:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items (no Fast LTA Headunit data)",
            "data": {"discovery": []},
        }

    # Check mode for single service (item is always "")
    # Get all Fast LTA Headunit OIDs in one call
    res = ctx.run([
        "snmpwalk", "-On", "-Ovq",
        ".1.3.6.1.4.1.27417.2.1",  # headunit status
        ".1.3.6.1.4.1.27417.2.1.0",  # replication mode
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Fast LTA Headunit data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse snmpwalk output - format: OID = value
    lines = res.stdout.splitlines()
    headunit_status = ""
    app_read_only_status = ""
    node_replication_mode = ""
    replication_status = ""
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Extract value after '=' or just the last part
        if "=" in line:
            parts = line.split("=", 1)
            value = parts[1].strip() if len(parts) > 1 else ""
        else:
            value = line
        
        # Determine OID type by looking at the full OID context
        if line.find(".1.3.6.1.4.1.27417.2.1.1") != -1:
            headunit_status = value
        elif line.find(".1.3.6.1.4.1.27417.2.1.2") != -1:
            app_read_only_status = value
        elif line.find(".1.3.6.1.4.1.27417.2.1.0") != -1:
            node_replication_mode = value
    
    # Also try to get replication status from same section
    # Replication status is likely at .1.3.6.1.4.1.27417.2.1.5 (based on original code section[0][0][2])
    # but the original code used section[0][0][1:3] for replication, so we assume it's in the same table
    # We'll search for the replication status value by looking for a second value
    if res.stdout.find(".1.3.6.1.4.1.27417.2.1.5") != -1:
        for line in lines:
            line = line.strip()
            if line.find(".1.3.6.1.4.1.27417.2.1.5") != -1:
                if "=" in line:
                    parts = line.split("=", 1)
                    replication_status = parts[1].strip() if len(parts) > 1 else ""
                else:
                    replication_status = line
    
    # If we still don't have replication_status, try to derive from output structure
    # Original code used section[0][0][1:3] -> values at index 1 and 2
    # So let's parse the raw output more carefully
    raw = res.stdout.strip()
    if raw:
        # Split into lines and extract values
        values = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if "=" in line:
                values.append(line.split("=", 1)[1].strip())
            else:
                values.append(line)
        
        # If we have at least 3 values, extract replication data
        if len(values) >= 3:
            if node_replication_mode == "":
                node_replication_mode = values[1]
            if replication_status == "":
                replication_status = values[2]
    
    # Ensure we have headunit status
    if headunit_status == "":
        # Try to find any value from the section
        for line in lines:
            line = line.strip()
            if line.find(".1.3.6.1.4.1.27417.2.1.1") != -1:
                if "=" in line:
                    headunit_status = line.split("=", 1)[1].strip()
                else:
                    headunit_status = line
    
    # If still no status, we cannot determine state
    if headunit_status == "":
        return {
            "changed": False,
            "msg": "Fast LTA Headunit status unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Determine state based on headunit status (original check logic)
    state = "CRIT"
    message = ""
    
    if headunit_status == "60":
        state = "OK"
        message = "Head Unit status is appReady."
    elif headunit_status == "70" and app_read_only_status == "0":
        # on Slave node appReadOnly is also an ok state
        state = "OK"
        message = "Head Unit status is appReadOnly."
    else:
        # Map the status if available
        if headunit_status in HEADUNIT_STATUS_MAP:
            message = "Head Unit status is " + HEADUNIT_STATUS_MAP[headunit_status] + "."
        else:
            message = "Head Unit status is " + headunit_status + "."
    
    # Add replication info if available
    if node_replication_mode != "" or replication_status != "":
        replication_msg = ""
        
        # Replication status
        if replication_status == "1":
            replication_msg = "Replication is running."
            state = "OK"  # Replication status overrides only if it's OK
        elif replication_status == "":
            # If no replication status, just note it if we have mode
            pass
        else:
            replication_msg = "Replication is not running (!!)."
        
        # Node replication mode
        if node_replication_mode != "":
            if node_replication_mode in REPLICATION_MODE_MAP:
                replication_msg += " This node is " + REPLICATION_MODE_MAP[node_replication_mode] + "."
            else:
                replication_msg += " Replication mode of this node is " + node_replication_mode + "."
        
        if replication_msg != "":
            message = message + " " + replication_msg.strip()
    
    return {
        "changed": False,
        "msg": message,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
