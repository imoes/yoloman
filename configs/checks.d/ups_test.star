# Constants for SNMP OIDs and mappings
UPS_TEST_BASE_OID = ".1.3.6.1.2.1.33.1.7"
SYS_UPTIME_BASE_OID = ".1.3.6.1.2.1.1.3"

# Test result mapping
_TEST_RESULT_SUMMARY_MAP = {
    "1": "passed",
    "2": "warning",
    "3": "error",
    "4": "aborted",
    "5": "in progress",
    "6": "no tests initiated",
}

_SUMMARY_STATE_MAP = {
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "CRIT",
    "5": "OK",
    "6": "OK",
}

def _parse_uptime_seconds(uptime_str):
    """Parse SNMP uptime string to seconds (centiseconds)."""
    # Handle empty or None values
    if uptime_str == None or uptime_str == "":
        return None
    
    # Check if it's a simple number (centiseconds)
    if uptime_str.isdigit():
        return int(uptime_str) / 100.0
    
    # Handle Timeticks format: "Timeticks: (12345678) 1:20:34:27"
    if uptime_str.startswith("Timeticks: "):
        idx1 = uptime_str.find(")")
        if idx1 != -1:
            time_part = uptime_str[idx1+2:].strip()
            parts = time_part.split(":")
            if len(parts) == 3:
                h = int(parts[0]) if parts[0].isdigit() else 0
                m = int(parts[1]) if parts[1].isdigit() else 0
                s_part = parts[2].split(".")[0] if "." in parts[2] else parts[2]
                s = int(s_part) if s_part.isdigit() else 0
                return h * 3600 + m * 60 + s
        return None
    
    # Try standard format: hours:minutes:seconds.centiseconds
    parts = uptime_str.split(":")
    if len(parts) == 3:
        h = int(parts[0]) if parts[0].isdigit() else 0
        m = int(parts[1]) if parts[1].isdigit() else 0
        s_part = parts[2].split(".")[0] if "." in parts[2] else parts[2]
        s = int(s_part) if s_part.isdigit() else 0
        return h * 3600 + m * 60 + s
    
    return None

def _get_snmp_value(ctx, community, host, base_oid, oid_suffix):
    """Get a single SNMP value using snmpget."""
    full_oid = base_oid + "." + oid_suffix
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, full_oid
    ], mutates=False)
    if res.rc != 0:
        return None
    
    # Parse output like: ".1.3.6.1.2.1.33.1.7.3.0 = INTEGER: 1"
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return None
    line = lines[0].strip()
    if line == "":
        return None
    
    # Extract value after " = "
    idx = line.find(" = ")
    if idx == -1:
        return None
    value_part = line[idx+3:].strip()
    
    # Extract just the value (remove type prefix like "INTEGER: ", "STRING: ", etc.)
    if value_part.startswith("INTEGER: "):
        return value_part[9:]
    elif value_part.startswith("STRING: "):
        # Remove surrounding quotes
        s = value_part[8:]
        if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            return s[1:-1]
        return s
    elif value_part.startswith("Timeticks: "):
        # Parse Timeticks format
        t = value_part[11:]
        idx2 = t.find(")")
        if idx2 != -1:
            t = t[idx2+2:].strip()
        return _parse_uptime_seconds(t)
    else:
        return value_part

def main(ctx, params):
    # Get parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        # Discovery: check if ups_test section exists (by querying any OID)
        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On", host, 
            ".1.3.6.1.2.1.33.1.7.3.0"
        ], mutates=False)
        if res.rc == 0 and res.stdout.strip() != "":
            return {
                "changed": False,
                "msg": "discovered 1 services",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"levels_elapsed_time": ("no_levels", None)},
                            "metrics": []
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "no services discovered",
            "data": {"discovery": []}
        }
    
    # Check mode: fetch all required SNMP values
    # sysUpTime.0
    uptime_value = _get_snmp_value(ctx, community, host, SYS_UPTIME_BASE_OID, "0")
    # upsTestResultsSummary.0
    test_result = _get_snmp_value(ctx, community, host, UPS_TEST_BASE_OID, "3")
    # upsTestStartTime.0
    start_time_value = _get_snmp_value(ctx, community, host, UPS_TEST_BASE_OID, "5")
    # upsTestResultsDetail.0
    test_detail = _get_snmp_value(ctx, community, host, UPS_TEST_BASE_OID, "4")
    
    # Validate data presence
    if uptime_value == None or test_result == None or start_time_value == None:
        return {
            "changed": False,
            "msg": "could not retrieve UPS test information",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse uptime and start time to seconds
    uptime_sec = _parse_uptime_seconds(str(uptime_value))
    start_sec = _parse_uptime_seconds(str(start_time_value))
    
    # Determine state from test result
    state = _SUMMARY_STATE_MAP.get(str(test_result), "UNKNOWN")
    
    # Build result message
    test_summary = _TEST_RESULT_SUMMARY_MAP.get(str(test_result), "unknown")
    details = ""
    if test_detail != None and test_detail != "":
        details = " (" + str(test_detail) + ")"
    
    # Elapsed time calculation
    elapsed_sec = None
    if uptime_sec != None and start_sec != None:
        elapsed_sec = uptime_sec - start_sec
    
    # Special case: start_time == 0 means no test since device boot
    if start_sec == 0 or start_sec == None:
        label = "Uptime"
        elapsed_sec = uptime_sec
    
    # Prepare metrics (only report elapsed time if valid)
    metrics = {}
    if elapsed_sec != None and elapsed_sec >= 0:
        metrics["elapsed_time"] = elapsed_sec
    
    # Check levels if provided (we expect tuple or "no_levels" in params)
    levels = params.get("levels_elapsed_time", ("no_levels", None))
    warn_val = None
    crit_val = None
    if levels != None and levels != "no_levels" and type(levels) == "list":
        if len(levels) >= 1:
            warn_val = levels[0]
        if len(levels) >= 2:
            crit_val = levels[1]
    
    # Adjust state based on elapsed time if levels are set
    if elapsed_sec != None and elapsed_sec >= 0 and (warn_val != None or crit_val != None):
        if crit_val != None and elapsed_sec >= crit_val:
            state = "CRIT"
        elif warn_val != None and elapsed_sec >= warn_val:
            state = "WARN"
    
    # Build human-readable message
    msg = "Last test: " + test_summary + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }